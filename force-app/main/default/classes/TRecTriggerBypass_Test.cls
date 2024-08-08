@isTest
private class TRecTriggerBypass_Test {

    @isTest
    static void testSetExpiryMinutes() {
        Integer numberOfMinutes = 75;
        TRecTriggerBypass tb = new TRecTriggerBypass();

        Test.startTest();
        tb.setExpiryMinutes(numberOfMinutes);
        Test.stopTest();

        Assert.areEqual(numberOfMinutes, tb.expiryMinutes, 'Should have overridden the private expiryMinutes variable');
    }

    @isTest
    static void testAddObject() {
        String sObjectName = 'TREX1__Journal_Entry__c';
        TRecTriggerBypass tb = new TRecTriggerBypass();

        Test.startTest();
        tb.addObject(sObjectName);
        Test.stopTest();

        Assert.isTrue(tb.setSObjectNames.contains(sObjectName), 'Collection of sobject names should have included provided name');
    }

    @isTest
    static void testBypassAll() {
        String sObjectName1 = 'TREX1__Journal_Entry__c';
        String sObjectName2 = 'TREX1__Transaction__c';
        TRecTriggerBypass tb = new TRecTriggerBypass();
        tb.addObject(sObjectName1);
        tb.addObject(sObjectName2);

        Test.startTest();
        tb.bypassAll();
        Test.stopTest();

        List<TREX1__Trigger_Bypass__c> bypassesToVerify = [
            SELECT Id, TREX1__Active__c
              FROM TREX1__Trigger_Bypass__c 
             WHERE TREX1__SObject__c = :sObjectName1
                OR TREX1__SObject__c = :sObjectName2
             LIMIT 2
        ];

        for (TREX1__Trigger_Bypass__c bypass : bypassesToVerify) {
            Assert.isTrue(bypass.TREX1__Active__c, 'Bypass for provided sobject name should be active');
        }
    }

    @isTest
    static void testBypassAllWithNotes() {
        String sObjectName1  = 'TREX1__Journal_Entry__c';
        String sObjectName2  = 'TREX1__Transaction__c';
        String notes         = 'Bypassing stuff';
        TRecTriggerBypass tb = new TRecTriggerBypass();
        tb.addObject(sObjectName1);
        tb.addObject(sObjectName2);

        Test.startTest();
        tb.bypassAll(notes);
        Test.stopTest();

        List<TREX1__Trigger_Bypass__c> bypassesToVerify = [
            SELECT Id, TREX1__Active__c, TREX1__Notes__c
              FROM TREX1__Trigger_Bypass__c 
             WHERE TREX1__SObject__c = :sObjectName1
                OR TREX1__SObject__c = :sObjectName2
             LIMIT 2
        ];

        for (TREX1__Trigger_Bypass__c bypass : bypassesToVerify) {
            Assert.isTrue(bypass.TREX1__Active__c, 'Bypass for provided sobject name should be active');
            Assert.areEqual(notes, bypass.TREX1__Notes__c, 'Notes should have included provided string');
        }
    }

    @isTest
    static void testSingleBypass() {
        String sObjectName   = 'TREX1__Journal_Entry__c';
        TRecTriggerBypass tb = new TRecTriggerBypass();

        Test.startTest();
        tb.bypass(sObjectName);
        Test.stopTest();

        TREX1__Trigger_Bypass__c bypassToVerify = [
            SELECT Id, TREX1__Active__c
              FROM TREX1__Trigger_Bypass__c 
             WHERE TREX1__SObject__c = :sObjectName
             LIMIT 1
        ];

        Assert.isTrue(bypassToVerify.TREX1__Active__c, 'Bypass for provided sobject name should be active');
    }

    @isTest
    static void testSingleBypassWithNotes() {
        String sObjectName   = 'TREX1__Journal_Entry__c';
        String notes         = 'Bypassing stuff';
        TRecTriggerBypass tb = new TRecTriggerBypass();

        Test.startTest();
        tb.bypass(sObjectName, notes);
        Test.stopTest();

        TREX1__Trigger_Bypass__c bypassToVerify = [
            SELECT Id, TREX1__Active__c, TREX1__Notes__c
              FROM TREX1__Trigger_Bypass__c 
             WHERE TREX1__SObject__c = :sObjectName
             LIMIT 1
        ];

        Assert.isTrue(bypassToVerify.TREX1__Active__c, 'Bypass for provided sobject name should be active');
        Assert.areEqual(notes, bypassToVerify.TREX1__Notes__c, 'Notes should have included provided string');
    }

    @isTest
    static void testSingleBypassForExistingRecord() {
        String sObjectName   = 'TREX1__Journal_Entry__c';

        // Create trigger bypass record so an existing record can be activated in the test
        TREX1__Trigger_Bypass__c existingBypass = new TREX1__Trigger_Bypass__c(
            Name = sObjectName,
            TREX1__SObject__c = sObjectName,
            TREX1__Active__c = false,
            TREX1__Expiry__c = Datetime.now().addHours(-1),
            TREX1__Notes__c = sObjectName
        );
        insert existingBypass;

        TRecTriggerBypass tb = new TRecTriggerBypass();

        Test.startTest();
        tb.bypass(sObjectName);
        Test.stopTest();

        TREX1__Trigger_Bypass__c bypassToVerify = [
            SELECT Id, TREX1__Active__c
              FROM TREX1__Trigger_Bypass__c 
             WHERE TREX1__SObject__c = :sObjectName
             LIMIT 1
        ];

        Assert.isTrue(bypassToVerify.TREX1__Active__c, 'Bypass for provided sobject name should be active');
    }

    @isTest
    static void testSkipBypassForActiveRecord() {
        String sObjectName   = 'TREX1__Journal_Entry__c';
        Datetime expiryTime  = Datetime.now().addHours(1);

        // Create trigger bypass record so an existing record can be activated in the test
        TREX1__Trigger_Bypass__c existingBypass = new TREX1__Trigger_Bypass__c(
            Name = sObjectName,
            TREX1__SObject__c = sObjectName,
            TREX1__Active__c = true,
            TREX1__Expiry__c = expiryTime,
            TREX1__User_Ids__c = UserInfo.getUserId(),
            TREX1__Notes__c = sObjectName
        );
        insert existingBypass;

        TRecTriggerBypass tb = new TRecTriggerBypass();

        Test.startTest();
        tb.bypass(sObjectName);
        Test.stopTest();

        TREX1__Trigger_Bypass__c bypassToVerify = [
            SELECT Id, TREX1__Active__c, TREX1__Expiry__c
              FROM TREX1__Trigger_Bypass__c 
             WHERE Id = :existingBypass.Id
             LIMIT 1
        ];

        Assert.isTrue(bypassToVerify.TREX1__Active__c, 'Bypass for provided sobject name should still be active');
        Assert.areEqual(expiryTime, bypassToVerify.TREX1__Expiry__c, 'Original expiry time should have been preserved');
    }

    @isTest
    static void testActivateBypasses() {
        String sObjectName   = 'TREX1__Journal_Entry__c';
        Datetime expiryTime  = Datetime.now().addHours(1);

        // Create trigger bypass record so an existing record can be activated in the test
        TREX1__Trigger_Bypass__c existingBypass = new TREX1__Trigger_Bypass__c(
            Name = sObjectName,
            TREX1__SObject__c = sObjectName,
            TREX1__Active__c = true,
            TREX1__Expiry__c = expiryTime,
            TREX1__User_Ids__c = UserInfo.getUserId(),
            TREX1__Notes__c = sObjectName
        );
        insert existingBypass;

        TRecTriggerBypass tb = new TRecTriggerBypass();

        Test.startTest();
        tb.bypass(sObjectName);
        Test.stopTest();

        TREX1__Trigger_Bypass__c bypassToVerify = [
            SELECT Id, TREX1__Active__c, TREX1__Expiry__c, TREX1__User_Ids__c
              FROM TREX1__Trigger_Bypass__c 
             WHERE Id = :existingBypass.Id
             LIMIT 1
        ];

        Assert.isTrue(bypassToVerify.TREX1__Active__c, 'Bypass for provided sobject name should still be active');
        Assert.areEqual(expiryTime, bypassToVerify.TREX1__Expiry__c, 'Original expiry time should have been preserved');
        Assert.isTrue(bypassToVerify.TREX1__User_Ids__c.contains(UserInfo.getUserId()), 'Bypass should include the running user\'s id');
    }

    @isTest
    static void testDisableSingleBypass() {
        String sObjectName1 = 'TREX1__Journal_Entry__c';
        String sObjectName2 = 'TREX1__Transaction__c';

        TRecTriggerBypass tb = new TRecTriggerBypass();
        tb.addObject(sObjectName1);
        tb.addObject(sObjectName2);
        tb.bypassAll();

        Test.startTest();
        tb.disableBypass(sObjectName1);
        Test.stopTest();

        List<TREX1__Trigger_Bypass__c> bypassesToVerify = [
            SELECT Id, TREX1__SObject__c, TREX1__Active__c
              FROM TREX1__Trigger_Bypass__c 
             WHERE TREX1__SObject__c = :sObjectName1
                OR TREX1__SObject__c = :sObjectName2
             LIMIT 2
        ];

        Map<String, TREX1__Trigger_Bypass__c> mapObjNameToBypass = new Map<String, TREX1__Trigger_Bypass__c>();
        for (TREX1__Trigger_Bypass__c bypassToVerify : bypassesToVerify) {
            mapObjNameToBypass.put(bypassToVerify.TREX1__SObject__c, bypassToVerify);
        }

        Assert.isFalse(mapObjNameToBypass.get(sObjectName1).TREX1__Active__c, 'The first sobject bypass should have been deactivated');
        Assert.isTrue(mapObjNameToBypass.get(sObjectName2).TREX1__Active__c, 'The second sobject bypass should not have been deactivated');
    }

    @isTest
    static void testDisableAllBypasses() {
        String sObjectName1 = 'TREX1__Journal_Entry__c';
        String sObjectName2 = 'TREX1__Transaction__c';

        TRecTriggerBypass tb = new TRecTriggerBypass();
        tb.addObject(sObjectName1);
        tb.addObject(sObjectName2);
        tb.bypassAll();

        Test.startTest();
        tb.disableAllBypasses();
        Test.stopTest();

        List<TREX1__Trigger_Bypass__c> bypassesToVerify = [
            SELECT Id, TREX1__Active__c
              FROM TREX1__Trigger_Bypass__c 
             WHERE TREX1__SObject__c = :sObjectName1
                OR TREX1__SObject__c = :sObjectName2
             LIMIT 2
        ];

        for (TREX1__Trigger_Bypass__c bypass : bypassesToVerify) {
            Assert.isFalse(bypass.TREX1__Active__c, 'The first sobject bypass should have been deactivated');
        }
    }
    
}