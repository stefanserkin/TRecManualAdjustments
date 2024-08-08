@isTest
private class TRecCreditExpirationBatch_Test {

    @testSetup
    static void makeData() {
        // Create App Config custom setting
        TestDataFactory.createAppConfig();
        TREX1__App_Config__c appConfig = TREX1__App_Config__c.getOrgDefaults();
        Integer numDaysToBackdate = Integer.valueOf(appConfig.Days_Until_Credit_Expiration__c) + 10;
        // Create global accounts in custom settings
        TREX1__Global_GL_Accounts__c globalGlAccounts = TestDataFactory.createGlobalGLAccounts();
        // Create gl accounts in custom object
        List<TREX1__GL_Account__c> lstGlAccounts = TestDataFactory.createGlAccounts(5);
        insert lstGlAccounts;
        // Create global billing group
        TREX1__Global_Billing_Group__c gbg = TestDataFactory.createGlobalBillingGroup();
        // Create 50 contacts in separate households
        List<Contact> lstContactsToInsert = TestDataFactory.createContacts(50);
        insert lstContactsToInsert;
        // Refresh list with account ids before creating journal entries
        List<Contact> lstContacts = [SELECT Id, AccountId FROM Contact WHERE Id IN :lstContactsToInsert];

        // Create credits eligible to expire for each contact
        Decimal baseAmountToExpire = 50.00;
        List<TREX1__Journal_Entry__c> lstArCredits = TestDataFactory.createCreditsEligibleToExpire(
            lstContacts, 
            lstGlAccounts, 
            numDaysToBackdate, 
            baseAmountToExpire
        );
    }

    @isTest 
    static void testBatch() {
        Test.startTest();
        TRecCreditExpirationBatch batch = new TRecCreditExpirationBatch();
        Id batchId = Database.executeBatch(batch, 50);
        Test.stopTest();
        
        List<TREX1__Journal_Entry__c> lstUnexpiredJes = [
            SELECT Id FROM TREX1__Journal_Entry__c WHERE TREX1__Unapplied_Credit_Amount__c > 0
        ];
        Assert.isTrue(lstUnexpiredJes.isEmpty(), 'All journal entries should have expired');

        List<Account> lstAccsWithCredit = [
            SELECT Id FROM Account WHERE TREX1__Unapplied_Credit_Amount__c > 0
        ];
        Assert.isTrue(lstAccsWithCredit.isEmpty(), 'No accounts should have a positive credit remaining');
    }
    
    @isTest
    static void testMultipleRevenueAccounts() {
        String arGlCode = TREX1__Global_GL_Accounts__c.getOrgDefaults().TREX1__Accounts_Receivable__c;
        // Get any debit je inserted in TestSetup
        TREX1__Journal_Entry__c existingCreditJe = [
            SELECT Id, TREX1__Contact__c, TREX1__Account__c, TREX1__GL_Code__c 
              FROM TREX1__Journal_Entry__c 
             WHERE TREX1__GL_Code__c != :arGlCode
             LIMIT 1
        ];
        Contact ct = new Contact(Id = existingCreditJe.TREX1__Contact__c, AccountId = existingCreditJe.TREX1__Account__c);
        // Get a different non-AR GL account
        TREX1__GL_Account__c glAcc = [
            SELECT Id, TREX1__GL_Account_Number__c 
              FROM TREX1__GL_Account__c
             WHERE TREX1__GL_Account_Number__c != :existingCreditJe.TREX1__GL_Code__c
               AND TREX1__GL_Account_Number__c != :arGlCode
             LIMIT 1
        ];
        // Create one more credit to expire for this contact/account
        List<TREX1__Journal_Entry__c> lstArCredits = TestDataFactory.createCreditsEligibleToExpire(
            new List<Contact>{ ct }, 
            new List<TREX1__GL_Account__c>{ glAcc }, 
            Integer.valueOf(TREX1__App_Config__c.getOrgDefaults().Days_Until_Credit_Expiration__c) + 20, 
            100
        );
        
        Test.startTest();
        TRecCreditExpirationBatch batch = new TRecCreditExpirationBatch();
        Id batchId = Database.executeBatch(batch, 50);
        Test.stopTest();

        List<Account> lstAccsWithCredit = [
            SELECT Id FROM Account WHERE TREX1__Unapplied_Credit_Amount__c > 0
        ];
        Assert.isTrue(lstAccsWithCredit.isEmpty(), 'No accounts should have a positive credit remaining');
    }

    @isTest
    static void testExpireMultipleJesFromSingleWrapper() {
        String arGlCode = TREX1__Global_GL_Accounts__c.getOrgDefaults().TREX1__Accounts_Receivable__c;
        // Get any debit je inserted in TestSetup
        TREX1__Journal_Entry__c existingCreditJe = [
            SELECT Id, TREX1__Contact__c, TREX1__Account__c, TREX1__GL_Code__c 
              FROM TREX1__Journal_Entry__c 
             WHERE TREX1__GL_Code__c != :arGlCode
             LIMIT 1
        ];
        Contact ct = new Contact(Id = existingCreditJe.TREX1__Contact__c, AccountId = existingCreditJe.TREX1__Account__c);
        TREX1__GL_Account__c glAcc = new TREX1__GL_Account__c(TREX1__GL_Account_Number__c = existingCreditJe.TREX1__GL_Code__c);
        // Create one more credit to expire for this contact/account
        List<TREX1__Journal_Entry__c> lstArCredits = TestDataFactory.createCreditsEligibleToExpire(
            new List<Contact>{ ct }, 
            new List<TREX1__GL_Account__c>{ glAcc }, 
            Integer.valueOf(TREX1__App_Config__c.getOrgDefaults().Days_Until_Credit_Expiration__c) + 20, 
            100
        );
        
        Test.startTest();
        TRecCreditExpirationBatch batch = new TRecCreditExpirationBatch();
        Id batchId = Database.executeBatch(batch, 50);
        Test.stopTest();

        List<Account> lstAccsWithCredit = [
            SELECT Id FROM Account WHERE TREX1__Unapplied_Credit_Amount__c > 0
        ];
        Assert.isTrue(lstAccsWithCredit.isEmpty(), 'No accounts should have a positive credit remaining');
    }

}