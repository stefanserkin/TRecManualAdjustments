/**
 * Create manual adjustments in flows
 * @date 2024
 */
public with sharing class FlowTRecManualAdjuster {

    @InvocableMethod(label='Create Manual Adjustments' category='Utilities')
    public static List<Result> createManualAdjustments(
        List<Request> lstRequests
    ) {
        List<Result> lstResults = new List<Result>();
        for (Request req : lstRequests) {
            Result result = new Result();
            TRecManualAdjustmentService serv = new TRecManualAdjustmentService(req.lstWrappers);
            if (!String.isBlank(req.description)) {
                serv.description = req.description;
            }
            result.lstTransactionIds = serv.createAdjustments();
            lstResults.add(result);
        }
        return lstResults;
    }

    public class Request {
        @InvocableVariable(required=true label='Manual Adjustment Wrappers' description='List of data wrappers to create adjustments for')
        public List<TRecManualAdjustmentWrapper> lstWrappers;
        @InvocableVariable(label='Description')
        public String description;
    }

    public class Result {
        @InvocableVariable(label='Manual Adjustment Transaction IDs')
        public List<Id> lstTransactionIds;
    }
}