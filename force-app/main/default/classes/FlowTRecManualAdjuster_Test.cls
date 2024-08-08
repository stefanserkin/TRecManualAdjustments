@IsTest
private class FlowTRecManualAdjuster_Test {

    @TestSetup
    static void makeData() {
        // Create App Config custom setting
        TestDataFactory.createAppConfig();
        TREX1__App_Config__c appConfig = TREX1__App_Config__c.getOrgDefaults();
        // Create global accounts in custom settings
        TREX1__Global_GL_Accounts__c globalGlAccounts = TestDataFactory.createGlobalGLAccounts();
        // Create gl accounts in custom object
        List<TREX1__GL_Account__c> lstGlAccounts = TestDataFactory.createGlAccounts(5);
        insert lstGlAccounts;
        // Create global billing group
        TREX1__Global_Billing_Group__c gbg = TestDataFactory.createGlobalBillingGroup();
        // Create 50 contacts in separate households
        List<Contact> lstContactsToInsert = TestDataFactory.createContacts(5);
        insert lstContactsToInsert;
    }
    
    @IsTest
    static void testCreateCreditAdjustment() {
        Contact ct = [SELECT Id, AccountId FROM Contact LIMIT 1];
        TREX1__GL_Account__c glAcc = [SELECT Id, TREX1__GL_Account_Number__c FROM TREX1__GL_Account__c LIMIT 1];
        Decimal amount = 100.00;
        String description = 'Adjust stuff';

        TRecManualAdjustmentWrapper wrapper = new TRecManualAdjustmentWrapper();
        wrapper.accountId = ct.AccountId;
        wrapper.contactId = ct.Id;
        wrapper.amount    = amount;
        wrapper.glCode    = glAcc.TREX1__GL_Account_Number__c;
        wrapper.type      = 'Credit';

        List<FlowTRecManualAdjuster.Result> lstResults;
        Test.startTest();
        FlowTRecManualAdjuster.Request req = new FlowTRecManualAdjuster.Request();
        req.lstWrappers = new List<TRecManualAdjustmentWrapper>{ wrapper };
        req.description = description;
        lstResults = FlowTRecManualAdjuster.createManualAdjustments(
            new List<FlowTRecManualAdjuster.Request>{ req }
        );
        Test.stopTest();

        List<Id> lstTransactionIds = lstResults[0].lstTransactionIds;
        TREX1__Journal_Entry__c jeToVerify = [
            SELECT Id, TREX1__Debit__c, TREX1__Annotation__c
              FROM TREX1__Journal_Entry__c 
             WHERE TREX1__Transaction__c IN :lstTransactionIds 
               AND TREX1__GL_Code__c = :wrapper.glCode
             LIMIT 1
        ];
        Assert.areEqual(
            amount, 
            jeToVerify.TREX1__Debit__c, 
            'Should have debited the provided gl account when creating the credit'
        );

        Assert.areEqual(
            description, 
            jeToVerify.TREX1__Annotation__c, 
            'Journal entries should have the provided description as their Annotation value'
        );

        Account acc = [SELECT TREX1__Unapplied_Credit_Amount__c FROM Account WHERE Id = :ct.AccountId LIMIT 1];
        
        Assert.areEqual(
            amount, 
            acc.TREX1__Unapplied_Credit_Amount__c, 
            'The account should have a credit of the adjusted amount'
        );
    }

}