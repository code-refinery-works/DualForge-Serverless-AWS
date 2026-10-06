import * as path from "path";
import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as kms      from "aws-cdk-lib/aws-kms";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as sqs      from "aws-cdk-lib/aws-sqs";
import * as lambda   from "aws-cdk-lib/aws-lambda";
import * as lambdaNode from "aws-cdk-lib/aws-lambda-nodejs";
import * as logs     from "aws-cdk-lib/aws-logs";
import * as apigw    from "aws-cdk-lib/aws-apigateway";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as iam      from "aws-cdk-lib/aws-iam";

interface Props extends cdk.StackProps {
  projectName: string;
  envName:     string;
}

export class ServerlessApiStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: Props) {
    super(scope, id, props);

    const { projectName: pj, envName: env } = props;
    const prefix  = `${pj}-${env}`;
    const isProd  = env === "prod";

    // ── KMS CMK ────────────────────────────────────────────
    const key = new kms.Key(this, "CmkKey", {
      alias:              `alias/${prefix}`,
      enableKeyRotation:  true,
      removalPolicy:      isProd ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
    });

    // ── DynamoDB ───────────────────────────────────────────
    const table = new dynamodb.Table(this, "ItemsTable", {
      tableName:          `${prefix}-items`,
      partitionKey:       { name: "PK", type: dynamodb.AttributeType.STRING },
      sortKey:            { name: "SK", type: dynamodb.AttributeType.STRING },
      billingMode:        dynamodb.BillingMode.PAY_PER_REQUEST,
      encryption:         dynamodb.TableEncryption.CUSTOMER_MANAGED,
      encryptionKey:      key,
      pointInTimeRecovery: true,
      deletionProtection: isProd,
      removalPolicy:      isProd ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
    });

    // ── SQS DLQ ────────────────────────────────────────────
    const dlq = new sqs.Queue(this, "Dlq", {
      queueName:            `${prefix}-dlq`,
      encryptionMasterKey:  key,
      retentionPeriod:      cdk.Duration.days(14),
      removalPolicy:        cdk.RemovalPolicy.DESTROY,
    });

    // ── Lambda Log Group ───────────────────────────────────
    const lambdaLogGroup = new logs.LogGroup(this, "LambdaLogs", {
      logGroupName:  `/aws/lambda/${prefix}-handler`,
      retention:     logs.RetentionDays.ONE_MONTH,
      encryptionKey: key,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ── Lambda Function ────────────────────────────────────
    const handler = new lambdaNode.NodejsFunction(this, "Handler", {
      functionName:  `${prefix}-handler`,
      entry:         path.join(__dirname, "../../src/index.mjs"),
      handler:       "handler",
      runtime:       lambda.Runtime.NODEJS_20_X,
      architecture:  lambda.Architecture.ARM_64,
      memorySize:    256,
      timeout:       cdk.Duration.seconds(10),
      tracing:       lambda.Tracing.ACTIVE,
      logGroup:      lambdaLogGroup,
      deadLetterQueue: dlq,
      environment:   { TABLE_NAME: table.tableName, LOG_LEVEL: "INFO" },
      bundling:      { minify: true, sourceMap: false, target: "node20", format: lambdaNode.OutputFormat.ESM },
    });

    table.grantReadWriteData(handler);
    key.grantDecrypt(handler);
    dlq.grantSendMessages(handler);
    handler.addToRolePolicy(new iam.PolicyStatement({
      actions:   ["xray:PutTraceSegments", "xray:PutTelemetryRecords"],
      resources: ["*"],
    }));

    // ── API Gateway Log Group ──────────────────────────────
    const apigwLogGroup = new logs.LogGroup(this, "ApigwLogs", {
      logGroupName:  `/aws/apigateway/${prefix}`,
      retention:     logs.RetentionDays.ONE_MONTH,
      encryptionKey: key,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ── API Gateway ────────────────────────────────────────
    const api = new apigw.LambdaRestApi(this, "Api", {
      restApiName:   `${prefix}-api`,
      handler:       handler,
      proxy:         false,
      endpointTypes: [apigw.EndpointType.REGIONAL],
      deployOptions: {
        stageName:          "v1",
        tracingEnabled:     true,
        accessLogDestination: new apigw.LogGroupLogDestination(apigwLogGroup),
        accessLogFormat:    apigw.AccessLogFormat.jsonWithStandardFields({
          caller: false, httpMethod: true, ip: true, protocol: false,
          requestTime: true, resourcePath: true, responseLength: false,
          status: true, user: false,
        }),
        throttlingRateLimit:  1000,
        throttlingBurstLimit: 2000,
      },
    });

    const items = api.root.addResource("items");
    items.addMethod("GET");
    items.addMethod("POST");

    // ── CloudWatch Alarms ──────────────────────────────────
    new cloudwatch.Alarm(this, "LambdaErrorAlarm", {
      alarmName:          `${prefix}-lambda-errors`,
      metric:             handler.metricErrors({ period: cdk.Duration.minutes(1) }),
      threshold:          5,
      evaluationPeriods:  1,
      treatMissingData:   cloudwatch.TreatMissingData.NOT_BREACHING,
    });
    new cloudwatch.Alarm(this, "Api5xxAlarm", {
      alarmName:          `${prefix}-apigw-5xx`,
      metric:             api.metricServerError({ period: cdk.Duration.minutes(1) }),
      threshold:          10,
      evaluationPeriods:  1,
      treatMissingData:   cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    // ── Outputs ────────────────────────────────────────────
    new cdk.CfnOutput(this, "ApiEndpoint",    { value: `${api.url}items` });
    new cdk.CfnOutput(this, "TableName",      { value: table.tableName });
    new cdk.CfnOutput(this, "LambdaName",     { value: handler.functionName });
    new cdk.CfnOutput(this, "KmsKeyArn",      { value: key.keyArn });
    new cdk.CfnOutput(this, "DlqUrl",         { value: dlq.queueUrl });
  }
}