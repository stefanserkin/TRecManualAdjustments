/************************************************
 * A staged credit expiration for use in the TRec Credit Expiration Batch
 *   TRecCreditExpirationBatch.cls
 * All properties are read/writeable
 ************************************************/
public class TRecExpiredCreditWrapper {

    /*******************************************
     * Wrapper Id - should probably create a UUID for the created objects
     * Currently, can be set by the requesting code as needed to make instantiated objects more accessible
     *******************************************/
    public String wrapperId {get; set;}

    /*******************************************
     * Account Id
     *******************************************/
    public Id accountId {get; set;}

    /*******************************************
     * Primary Contact Id
     *******************************************/
    public Id contactId {get; set;}

    /*******************************************
     * Amount of credit to expire
     *******************************************/
    public Decimal amountToExpire {get; set;}

    /*******************************************
     * GL code to credit in the expiration
     * Accounts Receivable will be debited
     *******************************************/
    public String glCodeToCredit {get; set;}

    /*******************************************
     * List of journal entries to expire
     * Should all represent debits to AR with a positive value of unlinked credits
     * Expiration debits to AR will be linked to these AR credits
     *******************************************/
    public List<TREX1__Journal_Entry__c> lstJEsToExpire {get; set;}
    
    /*******************************************
     * Transaction that expired the credits
     * Used in WhatId of confirmation task
     *******************************************/
    public Id transactionId {get; set;}

}