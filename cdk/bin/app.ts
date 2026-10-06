#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { ServerlessApiStack } from "../lib/stack";

const app = new cdk.App();

const env    = app.node.tryGetContext("env")     ?? "dev";
const project = app.node.tryGetContext("project") ?? "myapp";

new ServerlessApiStack(app, `${project}-${env}-ServerlessApi`, {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region:  process.env.CDK_DEFAULT_REGION ?? "ap-northeast-1",
  },
  projectName: project,
  envName:     env,
  tags: {
    Project:     project,
    Environment: env,
    ManagedBy:   "CDK",
  },
});