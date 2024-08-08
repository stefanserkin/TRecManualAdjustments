/****************************************************************************
 * @createdDate 2023-06-22
 * 
 * @description This batch expires Traction Rec credits by creating the equivalent of a manual adjustment 
 *   and linking the AR debit journal entry to the AR credit that is expiring.
 * 
 *   Batch Criteria and Settings
 *      - Only household accounts are subject to the policy. Organization accounts are excluded from the batch.
 *      - Houshold accounts with existing balances are not included in the batch, since the credits can be linked to 
 *          the existing balance.
 *      - Use the Days_Until_Credit_Expiration__c field in TREX1__App_Config__c custom setting to set the number of days before credits expire.
 *      - Use the Prevent_Credit_Exp_with_Active_BS__c field in TREX1__App_Config__c custom setting to prevent credits from expiring for accounts 
 *          that currently have at least one active billing schedule.
 *      - Use the Expired_Customer_Credits__c field in Global GL Accounts custom setting to define a default GL account to credit during expiration.
 *          When a revenue account is available, it will be credited. If no revenue account is found, the default GL account is used.
 * 
 * @TODO
 *   - Add flag to GL Account obj to indicate whether it can receive revenue from expired credits
 *      Also would be nice to have a way to designate a different account that should receive its expired credits
 *   - Handle revenue accounts from expiring credits that originated in a manual adjustment
 ****************************************************************************/
public with sharing class TRecCreditExpirationBatch implements Database.Batchable<sObject> {
    
    public static final String BATCH_NAME = 'TRec Credit Expiration Batch';

    private static final String ADJUSTMENT_DESCRIPTION  = 'Credit Expiration';
    private static final String TYPE_MANUAL_ADJUSTMENT  = 'Manual Adjustment';
    private static final String TRANSACTION_PARENT_FLOW = 'Credit Expiration Batch';
    private static final String STATUS_DRAFT            = 'Draft';
    private static final String STATUS_FIRMED           = 'Firmed';
    private static final String TASK_STATUS             = 'Completed';
    private static final String TASK_PRIORITY           = 'Normal';
    private static final String TASK_TYPE               = 'System';
    private static final String GBG_NAME                = 'Asphalt Green';
    private static final String DATETIME_FORMAT         = 'yyyy-MM-dd\'T\'HH:mm:ss:SSS';

    private static Id gbgId;
    private static Id taskUserId;
    private static String arGlCode;
    private static String expiredCreditGlCode;
    private static Decimal daysUntilCreditExpiration;
    private static Boolean preventCreditExpWithActiveBillingSchedule;
    private static Map<String, String> mapGlCodeToAccount;

    private static Id hhRecTypeId = Schema.SObjectType.Account
        .getRecordTypeInfosByDeveloperName().get('HH_Account').getRecordTypeId();
    private static Id tliRecTypeId = Schema.SObjectType.TREX1__Transaction_Line_Item__c
        .getRecordTypeInfosByDeveloperName().get('Manual_Adjustment').getRecordTypeId();

    private Map<String, TRecExpiredCreditWrapper> mapWrappers;

    /***************************************************
     * Start batch
     ***************************************************/
    public Database.QueryLocator start(Database.BatchableContext bc) {
        TREX1__App_Config__c appConfig = TREX1__App_Config__c.getOrgDefaults();
        // TODO - guard against null days until credit expiration
        Integer daysUntilExpiration = Integer.valueOf(appConfig.Days_Until_Credit_Expiration__c);
        Boolean preventCreditExpWithActiveBillingSchedule = appConfig.Prevent_Credit_Exp_with_Active_BS__c;

        // Get all household account ids with credits to expire
        // Accounts will be re-queried for journal entry details within the execute method
        String strQuery = 'SELECT Id FROM Account WHERE RecordTypeId = :hhRecTypeId AND (TREX1__Outstanding_Account_Balance__c = NULL OR TREX1__Outstanding_Account_Balance__c = 0)' + 
            ' AND Id IN (SELECT TREX1__Account__c FROM TREX1__Journal_Entry__c WHERE TREX1__Unapplied_Credit_Amount__c > 0 AND TREX1__Effective_Date_Time__c < LAST_N_DAYS:' + daysUntilExpiration + ')';

        // Check bypass for accounts with active billing schedules
        if (preventCreditExpWithActiveBillingSchedule) {
            strQuery += ' AND Id NOT IN (SELECT TREX1__Account__c FROM TREX1__Journal_Entry__c WHERE TREX1__Billing_Schedule__r.TREX1__Is_Billable__c = true)';
        }

        return Database.getQueryLocator(strQuery);
    }


    /***************************************************
     * Execute batch
     ***************************************************/
    public void execute(Database.BatchableContext bc, List<Account> lstAccounts) {
        // Set global gl info for accounts receivable and credit expiration
        setGlInfo();
        
        // Get a list of accounts with expired credit child jes
        List<Account> lstAccsWithCredits = getAccountsWithCredits(lstAccounts);
        // Convert to map of wrappers by wrapper id. Each represents a single transaction
        mapWrappers = wrapAccounts(lstAccsWithCredits);

        // Create one transaction for each wrapper
        List<TREX1__Transaction__c> lstTransactions = new List<TREX1__Transaction__c>();
        for (TRecExpiredCreditWrapper ecw : mapWrappers.values()) {
            lstTransactions.add( 
                getTransaction(ecw)
            );
        }
        insert lstTransactions;

        // Create one transaction line item for each transaction
        List<TREX1__Transaction_Line_Item__c> lstTlis = new List<TREX1__Transaction_Line_Item__c>();
        for (TREX1__Transaction__c trans : lstTransactions) {
            mapWrappers.get(trans.TREX1__Legacy_Id__c).transactionId = trans.Id;
            lstTlis.add( 
                getTli(trans, mapWrappers.get(trans.TREX1__Legacy_Id__c).amountToExpire) 
            );
        }
        insert lstTlis;

        // Create one accounting event for each transaction line item
        List<TREX1__Accounting_Event__c> lstAccountingEvents = new List<TREX1__Accounting_Event__c>();
        for (TREX1__Transaction_Line_Item__c tli : lstTlis) {
            lstAccountingEvents.add(
                getAccountingEvent(tli)
            );
        }
        insert lstAccountingEvents;

        // Create two journal entries for each accounting event
        List<TREX1__Journal_Entry__c> lstJes = new List<TREX1__Journal_Entry__c>();
        for (TREX1__Accounting_Event__c ae : lstAccountingEvents) {
            lstJEs.addAll(
                getJournalEntries(ae)
            );
        }
        insert lstJes;

        // Link debit jes to expiring credits
        List<TREX1__Payment_Link__c> lstPaymentLinks = new List<TREX1__Payment_Link__c>();
        // Filter list to only debits
        List<TREX1__Journal_Entry__c> lstArDebits = new List<TREX1__Journal_Entry__c>();
        for (TREX1__Journal_Entry__c je : lstJes) {
            if (je.TREX1__GL_Code__c == arGlCode) {
                lstArDebits.add(je);
            }
        }
        for (TREX1__Journal_Entry__c debitJe : lstArDebits) {
            // Retrieve list of corresponding credits to expire from the wrapper id stored in the legacy id field
            List<TREX1__Journal_Entry__c> lstCreditJes = mapWrappers.get(debitJe.TREX1__Legacy_Id__c).lstJEsToExpire;
            // Link the unapplied credit amount for each credit je to the debit je
            for (TREX1__Journal_Entry__c creditJe : lstCreditJes) {
                TREX1__Payment_Link__c pLink = new TREX1__Payment_Link__c();
                pLink.TREX1__AR_Debit__c  = debitJe.Id;
                pLink.TREX1__AR_Credit__c = creditJe.Id;
                pLink.TREX1__Amount__c    = creditJe.TREX1__Unapplied_Credit_Amount__c;
                lstPaymentLinks.add(pLink);
            }
        }
        insert lstPaymentLinks;

        // Set the transaction status to close
        // A Rec trigger will update the tli statuses, generate receipt pdfs, and recalculate account rollups
        for (TREX1__Transaction__c t : lstTransactions) {
            t.TREX1__Status__c = STATUS_FIRMED;
        }
        update lstTransactions;

        // Add tasks to accounts to indicate completed credit expiration
        List<Task> lstTasks = new List<Task>();
        for (TRecExpiredCreditWrapper ecWrap : mapWrappers.values()) {
            lstTasks.add(getTaskFromWrapper(ecWrap));
        }
        insert lstTasks;

    }


    /***************************************************
     * Finish batch
     ***************************************************/
    public void finish(Database.BatchableContext bc) {
        
        AsyncApexJob apexJob = [
            SELECT Id, 
                   Status, 
                   NumberOfErrors, 
                   JobItemsProcessed, 
                   TotalJobItems, 
                   CreatedBy.Email
              FROM AsyncApexJob 
             WHERE Id = :bc.getJobId()
        ];
        
        // Send email to job creator with batch results
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        String[] toAddress = new String[] {apexJob.CreatedBy.Email};
        email.setToAddresses(toAddress);
        email.setSubject(apexJob.Status + ': ' + BATCH_NAME);
        email.setPlainTextBody('The ' + BATCH_NAME + ' ran and processed ' + apexJob.TotalJobItems + ' batches with ' + apexJob.NumberOfErrors + ' failures. Job Id: ' + apexJob.Id);
        Messaging.sendEmail(new Messaging.SingleEmailMessage[] { email });
    }


    /***************************************************
     * Query for accounts with child credits to be expired
     *   Check Prevent_Credit_Exp_with_Active_BS__c setting in TREX1__App_Config__c 
     *   custom setting to determine which query to perform
     * @param List<Account> list of accounts in batch
     * @return List<Account> list of accounts with child credits to expire
     ***************************************************/

    private List<Account> getAccountsWithCredits(
        List<Account> lstAccounts
    ) {
        List<Account> lstAccsToReturn = new List<Account>();
        String strAccQuery = 'SELECT Id, npe01__One2OneContact__c, TREX1__Unapplied_Credit_Amount__c, (SELECT Id, TREX1__Credit__c, TREX1__Unapplied_Credit_Amount__c, TREX1__Effective_Date_Time__c, Revenue_GL_Account__c FROM TREX1__Journal_Entries__r' + 
            ' WHERE TREX1__Unapplied_Credit_Amount__c > 0 ';
        strAccQuery += ' AND TREX1__Effective_Date_Time__c < LAST_N_DAYS:' + daysUntilCreditExpiration + ' ORDER BY Revenue_GL_Account__c ASC LIMIT 10000)' + 
            ' FROM Account WHERE Id IN :lstAccounts';
        lstAccsToReturn = Database.query(strAccQuery);
        return lstAccsToReturn;
    }


    /***************************************************
     * Convert account/revenue gl combinations to a discrete wrapper object
     *   Each wrapper represents a single expiration transaction that needs to be created
     * @param List<Account> list of accounts with child credits to expire
     * @return List<TRecExpiredCreditWrapper> collection of wrapper objs representing a single transaction to create
     ***************************************************/

    private Map<String, TRecExpiredCreditWrapper> wrapAccounts(
        List<Account> lstAccsWithCredits
    ) {
        Map<String, TRecExpiredCreditWrapper> mapWrappers = new Map<String, TRecExpiredCreditWrapper>();

        // Give each wrapper a unique id to more easily reference it when needed. This unique id is written to the 
        // legacy id field of each record it generates (transaction, tli, accounting event, and journal entries)
        String wrapperPrefix   = Datetime.now().formatGmt(DATETIME_FORMAT);
        Integer wrapperCounter = 0;

        for (Account acc : lstAccsWithCredits) {
            // Track lists of journal entries and total dollar amounts per revenue account
            Map<String, List<TREX1__Journal_Entry__c>> mapRevGlsToJes = new Map<String, List<TREX1__Journal_Entry__c>>();
            Map<String, Decimal> mapRevGlsToAmount = new Map<String, Decimal>();

            for (TREX1__Journal_Entry__c je : acc.TREX1__Journal_Entries__r) {
                // Check for valid revenue account or apply the default expiration account
                String glCode = !String.isBlank(je.Revenue_GL_Account__c) ? je.Revenue_GL_Account__c : expiredCreditGlCode;
                // Add revenue account to map if it hasn't yet been added and set total amount to zero
                if (!mapRevGlsToJes.containsKey(glCode)) {
                    mapRevGlsToAmount.put(glCode, 0);
                    mapRevGlsToJes.put(glCode, new List<TREX1__Journal_Entry__c>());
                }
                // Add journal entry unapplied credit amount to amount to expire
                Decimal updatedAmount = mapRevGlsToAmount.get(glCode) + je.TREX1__Unapplied_Credit_Amount__c;
                mapRevGlsToAmount.put(glCode, updatedAmount);
                // Add journal entry to list for corresponding revenue account
                List<TREX1__Journal_Entry__c> lstJes = mapRevGlsToJes.get(glCode);
                lstJes.add(je);
                mapRevGlsToJes.put(glCode, lstJes);
            }

            // Create a wrapper for each gl account
            for (String glAcc : mapRevGlsToJes.keySet()) {
                // Increment counter to produce unique id
                wrapperCounter++;

                TRecExpiredCreditWrapper wrapper = new TRecExpiredCreditWrapper();
                wrapper.wrapperId      = wrapperPrefix + String.valueOf(wrapperCounter);
                wrapper.accountId      = acc.Id;
                wrapper.contactId      = acc.npe01__One2OneContact__c;
                wrapper.amountToExpire = mapRevGlsToAmount.get(glAcc);
                wrapper.glCodeToCredit = glAcc;
                wrapper.lstJEsToExpire = mapRevGlsToJes.get(glAcc);
                mapWrappers.put(wrapper.wrapperId, wrapper);
            }
        }

        return mapWrappers;
    }


    /***************************************************
     * Get a transaction for an expired credit wrapper
     * @param TRecExpiredCreditWrapper expired credit wrapper with transaction details
     * @return TREX1__Transaction__c transaction to be inserted
     ***************************************************/

    private TREX1__Transaction__c getTransaction(
        TRecExpiredCreditWrapper ecw
    ) {
        return new TREX1__Transaction__c(
            TREX1__Account__c = ecw.AccountId, 
            TREX1__Contact__c = ecw.ContactId, 
            TREX1__Created_Online__c = false, 
            TREX1__Status__c = STATUS_DRAFT, 
            TREX1__Exclude_From_Automatic_Cleanup__c = false, 
            TREX1__Parent_Flow__c = TRANSACTION_PARENT_FLOW,
            TREX1__Legacy_Id__c = ecw.wrapperId
        );
    }


    /***************************************************
     * Get a transaction line item for an expiration transaction
     * @param TREX1__Transaction__c expired credit transaction
     * @return TREX1__Transaction_Line_Item__c tli to be inserted
     ***************************************************/

    private TREX1__Transaction_Line_Item__c getTli(
        TREX1__Transaction__c trans, 
        Decimal amount
    ) {
        return new TREX1__Transaction_Line_Item__c(
            RecordTypeId = tliRecTypeId,                                // Record Type (manual adjustment)
            TREX1__Account__c = trans.TREX1__Account__c,                // Account
            TREX1__Effective_Date__c = Date.today(),                    // Effective Date
            TREX1__Contact__c = trans.TREX1__Contact__c,                // Contact
            TREX1__Transaction__c = trans.Id,                           // Transaction
            TREX1__Transaction_Contact__c = trans.TREX1__Contact__c,    // Transaction Contact
            TREX1__Description__c = ADJUSTMENT_DESCRIPTION,             // Description
            TREX1__Status__c = STATUS_DRAFT,                            // Status
            TREX1__Type__c = 'Item Event',                              // Type
            TREX1__Event_Type__c = TYPE_MANUAL_ADJUSTMENT,              // Event Type
            TREX1__Prorated_Recurring_Fee_Percentage__c = 0.00,         // Prorated_Recurring_Fee_Percentage
            TREX1__Prorated_Recurring_Fee_Amount__c = 0.00,             // Prorated Recurring Fee Amount
            TREX1__Charge_Purchase_Billing_Immediately__c = false,      // Charge Purchase Billing Immediately
            TREX1__Net_Price__c = amount,                               // Net Price
            TREX1__Initial_Fee_Amount__c = amount,                      // Initial Fee Amount
            TREX1__Is_Edited__c = false,                                // Is Edited
            TREX1__Override_Price__c = false,                           // Override Price
            TREX1__tli_Global_Billing_Group__c = getGbgId(),            // Global Billing Group
            TREX1__Override_Prerequisites__c = false,                   // Override Prerequisites
            TREX1__Deferred_Revenue_Recognition_Finished__c = true,     // Deferred Revenue Recognition Finished
            TREX1__Total_Deferred_Revenue__c = 0.00,                    // Total Deferred Revenue
            TREX1__Legacy_Id__c = trans.TREX1__Legacy_Id__c             // Wrapper id
        );
    }


    /***************************************************
     * Get an accounting event for an expiration transaction line item
     * @param TREX1__Transaction_Line_Item__c expired credit tli
     * @return TREX1__Accounting_Event__c accounting event to be inserted
     ***************************************************/

    private TREX1__Accounting_Event__c getAccountingEvent(
        TREX1__Transaction_Line_Item__c tli
    ) {
        return new TREX1__Accounting_Event__c(
            TREX1__System_Generated__c = false,                                          // System Generated
            TREX1__Type__c = TYPE_MANUAL_ADJUSTMENT,                                     // Type
            TREX1__Transaction__c = tli.TREX1__Transaction__c,                           // Transaction
            TREX1__Effective_Date_Time__c = Datetime.now(),                              // Effective Date Time
            TREX1__Transaction_Line_Item__c = tli.Id,                                    // Transaction Line Item
            TREX1__Total__c = tli.TREX1__Initial_Fee_Amount__c,                          // Total
            TREX1__Annotation__c = ADJUSTMENT_DESCRIPTION,                               // Annotation
            TREX1__Account__c = tli.TREX1__Account__c,                                   // Account
            TREX1__Contact__c = tli.TREX1__Contact__c,                                   // Contact
            TREX1__Legacy_Id__c = tli.TREX1__Legacy_Id__c                                // Wrapper id
        );
    }


    /***************************************************
     * Get a pair of journal entries for each expiration accounting event
     * @param TREX1__Accounting_Event__c expired credit accounting event
     * @return List<TREX1__Journal_Entry__c> list of journal entries to insert
     ***************************************************/

    private List<TREX1__Journal_Entry__c> getJournalEntries(
        TREX1__Accounting_Event__c ae
    ) {
        List<TREX1__Journal_Entry__c> lstJEs = new List<TREX1__Journal_Entry__c>();

        TREX1__Journal_Entry__c debitJe = new TREX1__Journal_Entry__c(
            TREX1__Effective_Date_Time__c = Datetime.now(),                              // Effective Date Time
            TREX1__Account__c = ae.TREX1__Account__c,                                    // Account
            TREX1__Contact__c = ae.TREX1__Contact__c,                                    // Contact
            TREX1__Type__c = TYPE_MANUAL_ADJUSTMENT,                                     // Type
            TREX1__Accounting_Event__c = ae.Id,                                          // Accounting Event
            TREX1__GL_Code__c = arGlCode,                                                // GL Code
            TREX1__Annotation__c = ADJUSTMENT_DESCRIPTION,                               // Annotation
            TREX1__Debit__c = ae.TREX1__Total__c,                                        // Debit
            TREX1__Credit__c = 0.00,                                                     // Credit
            TREX1__Is_Tax__c = false,                                                    // Is Tax
            TREX1__Allow_Unapply_Cred_In_Comm_Tx__c = false,                             // Allow Credit Amount usage in Community
            TREX1__Transaction_Line_Item__c = ae.TREX1__Transaction_Line_Item__c,        // Transaction Line Item
            TREX1__Transaction__c = ae.TREX1__Transaction__c,                            // Transaction
            TREX1__Available_Billing_Payment_Credit__c = false,                          // Credit Available For Billing Payment
            TREX1__Total_Reversed__c = 0.00,                                             // Total Reversed or Refunded
            TREX1__Has_Been_Summarized__c = false,                                       // Has Been Summarized
            TREX1__Legacy_Id__c = ae.TREX1__Legacy_Id__c,                                // Wrapper id
            Credit_Expiration_Batch__c = true                                            // Credit Expiration Batch
        );
        lstJEs.add(debitJe);

        TREX1__Journal_Entry__c creditJe = new TREX1__Journal_Entry__c(
            TREX1__Effective_Date_Time__c = Datetime.now(),                              // Effective Date Time
            TREX1__Account__c = ae.TREX1__Account__c,                                    // Account
            TREX1__Contact__c = ae.TREX1__Contact__c,                                    // Contact
            TREX1__Type__c = TYPE_MANUAL_ADJUSTMENT,                                     // Type
            TREX1__Accounting_Event__c = ae.Id,                                          // Accounting Event
            TREX1__GL_Code__c = mapWrappers.get(ae.TREX1__Legacy_Id__c).glCodeToCredit,  // GL Code
            TREX1__Annotation__c = ADJUSTMENT_DESCRIPTION,                               // Annotation
            TREX1__Debit__c = 0.00,                                                      // Debit
            TREX1__Credit__c = ae.TREX1__Total__c,                                       // Credit
            TREX1__Is_Tax__c = false,                                                    // Is Tax
            TREX1__Allow_Unapply_Cred_In_Comm_Tx__c = false,                             // Allow Credit Amount usage in Community
            TREX1__Transaction_Line_Item__c = ae.TREX1__Transaction_Line_Item__c,        // Transaction Line Item
            TREX1__Transaction__c = ae.TREX1__Transaction__c,                            // Transaction
            TREX1__Available_Billing_Payment_Credit__c = false,                          // Credit Available For Billing Payment
            TREX1__Total_Reversed__c = 0.00,                                             // Total Reversed or Refunded
            TREX1__Has_Been_Summarized__c = false,                                       // Has Been Summarized
            TREX1__Legacy_Id__c = ae.TREX1__Legacy_Id__c,                                // Wrapper id
            Credit_Expiration_Batch__c = true                                            // Credit Expiration Batch
        );
        lstJEs.add(creditJe);

        return lstJEs;
    }


    /***************************************************
     * Get a task for each expiration wrapper
     *   Tasks are completed and assigned to the default api user
     * @param TRecExpiredCreditWrapper expiration event wrapper
     * @return Task completed task
     ***************************************************/

    private Task getTaskFromWrapper(TRecExpiredCreditWrapper ecWrap) {
        Task t = new Task();
        String strTaskDescription = 'Credits ' + daysUntilCreditExpiration.format() + '+ days automatically expired';
        if (ecWrap.lstJEsToExpire.size() > 1) {
            strTaskDescription += '\nTotal Credits Expired: $' + ecWrap.amountToExpire.setScale(2);
        }

        // Detail expired journal entries for description
        for (TREX1__Journal_Entry__c expJe : ecWrap.lstJEsToExpire) {
            strTaskDescription += + '\n\n';
            strTaskDescription += 'Date Issued: ' + expJe.TREX1__Effective_Date_Time__c.format() + '\n';
            strTaskDescription += 'Expiration Date: ' + Date.today().format() + '\n';
            strTaskDescription += 'Amount Expired: $' + expJe.TREX1__Unapplied_Credit_Amount__c.setScale(2);
        }

        t.Description = strTaskDescription;
        t.Subject = ADJUSTMENT_DESCRIPTION;
        t.OwnerId = getTaskUserId();
        t.Status = TASK_STATUS;
        t.Priority = TASK_PRIORITY;
        t.Type = TASK_TYPE;
        t.WhoId = ecWrap.contactId;
        t.WhatId = ecWrap.transactionId;
        return t;
    }


    /***************************************************
     * Sets private static variables so that all gl info is accessible within the batch
     *   - Accounts Receivable gl code
     *   - Default Expired Credits Account gl code
     *   - Global setting for number of days before credits expire
     ***************************************************/

    private void setGlInfo() {
        // Get map of gl codes to account names from singleton
        mapGlCodeToAccount = TRecGLAccountUtility.getInstance().mapGlCodeToName;
        // Get Traction Rec default global gl accounts from custom setting
        TREX1__Global_GL_Accounts__c globalGls = TREX1__Global_GL_Accounts__c.getOrgDefaults();
        // Set static variables for AR and expired credit gl codes and number of days policy
        arGlCode = globalGls.TREX1__Accounts_Receivable__c;
        expiredCreditGlCode = globalGls.Expired_Customer_Credits__c;
        daysUntilCreditExpiration = Integer.valueOf(TREX1__App_Config__c.getOrgDefaults().Days_Until_Credit_Expiration__c);
    }


    /***************************************************
     * Asphalt Green only has one global billing group, so this makes the record id available
     * @return Id record id of the default global billing group
     ***************************************************/

    private Id getGbgId() {
        if (gbgId == null) {
            gbgId = [SELECT Id FROM TREX1__Global_Billing_Group__c WHERE Name = :GBG_NAME LIMIT 1].Id;
        }
        return gbgId;
    }


    /***************************************************
     * Tasks are created for each account with expired credits
     * These tasks should be assigned to the default api user
     * @return Id record id of the user to assign tasks to
     ***************************************************/

    private Id getTaskUserId() {
        if (taskUserId == null) {
            List<User> lstUsers = [
                SELECT Id 
                  FROM User 
                 WHERE Profile.Name = 'API Only' 
                   AND IsActive = true 
                 ORDER BY CreatedDate DESC 
                 LIMIT 1
            ];
            taskUserId = !lstUsers.isEmpty() ? lstUsers.get(0).Id : UserInfo.getUserId();
        }
        return taskUserId;
    }

}