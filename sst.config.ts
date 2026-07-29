/// <reference path="./.sst/platform/config.d.ts" />

/**
 * Slack adapter on lambda, behind a function URL.
 *
 * State lives in S3 rather than on the container filesystem, which is
 * ephemeral -- the store packs each category into one versioned object and
 * merges concurrent writers with a conditional PUT, so more than one warm
 * container can safely take evals.
 *
 * Secrets are sst secrets, set per stage:
 *   npx sst secret set SlackBotToken xoxb-...
 *   npx sst secret set SlackSigningSecret ...
 *   npx sst secret set SlackChannels C03QKEXDS
 */
export default $config({
  app(input) {
    return {
      name: "smeggdrop",
      home: "aws",
      removal: input?.stage === "prod" ? "retain" : "remove",
      protect: input?.stage === "prod",
      providers: {
        aws: {
          region: "us-west-2",
          // deploy.sh exports resolved credentials and clears AWS_PROFILE;
          // naming a profile here as well would send sst back down the
          // source_profile chain its sdk can't follow
          ...(process.env.AWS_PROFILE
            ? { profile: process.env.AWS_PROFILE }
            : {}),
        },
      },
    };
  },

  async run() {
    // versioned so a trashed proc library can be rolled back to any prior write
    const state = new sst.aws.Bucket("State", { versioning: true });

    // The store packs a whole category into one object, so every eval that
    // changes anything writes a full copy -- versions accumulate at roughly
    // 6 MB per changing eval, not per changed proc. Keep enough history to
    // undo a bad eval (or a bad day) without growing without bound.
    new aws.s3.BucketLifecycleConfigurationV2("StateLifecycle", {
      bucket: state.name,
      rules: [
        {
          id: "retain-recent-versions",
          status: "Enabled",
          filter: {},
          noncurrentVersionExpiration: {
            newerNoncurrentVersions: 200,
            noncurrentDays: 90,
          },
        },
        {
          id: "abort-incomplete-uploads",
          status: "Enabled",
          filter: {},
          abortIncompleteMultipartUpload: { daysAfterInitiation: 7 },
        },
      ],
    });

    // Versioning only survives a bad write; it does not survive the bucket
    // being deleted. A daily backup into a separate vault does.
    const backupRole = new aws.iam.Role("StateBackupRole", {
      assumeRolePolicy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [
          {
            Effect: "Allow",
            Principal: { Service: "backup.amazonaws.com" },
            Action: "sts:AssumeRole",
          },
        ],
      }),
    });
    for (const [name, arn] of [
      // these two live at the policy root, not under service-role/
      ["Backup", "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Backup"],
      ["Restore", "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Restore"],
    ]) {
      new aws.iam.RolePolicyAttachment(`StateBackupRole${name}`, {
        role: backupRole.name,
        policyArn: arn,
      });
    }

    const vault = new aws.backup.Vault("StateVault", {});
    const plan = new aws.backup.Plan("StatePlan", {
      rules: [
        {
          ruleName: "daily",
          targetVaultName: vault.name,
          schedule: "cron(0 9 * * ? *)", // 09:00 UTC, off-peak for a chat bot
          lifecycle: { deleteAfter: 35 },
        },
      ],
    });
    new aws.backup.Selection("StateSelection", {
      iamRoleArn: backupRole.arn,
      planId: plan.id,
      resources: [state.arn],
    });

    const botToken = new sst.Secret("SlackBotToken");
    const signingSecret = new sst.Secret("SlackSigningSecret");
    const channels = new sst.Secret("SlackChannels", "");

    const bot = new sst.aws.Function("Bot", {
      handler: "smeggdrop/lambda_handler.handler",
      runtime: "python3.13",
      python: { container: true },
      // the interp is rebuilt per cold start and evals are wall-clock capped,
      // so this only has to cover a cold start plus one eval
      timeout: "30 seconds",
      memory: "2048 MB",
      url: true,
      environment: {
        SLACK_BOT_TOKEN: botToken.value,
        SLACK_SIGNING_SECRET: signingSecret.value,
        SMEGGDROP_CHANNELS: channels.value,
        SMEGGDROP_STATE: $interpolate`s3://${state.name}/state`,
        SMEGGDROP_TIME_LIMIT: "5",
      },
      permissions: [
        {
          actions: ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
          resources: [state.arn, $interpolate`${state.arn}/*`],
        },
        {
          // bolt's lazy listeners ack inside slack's 3s window and then
          // re-invoke this same function to run the eval, so the role needs
          // to be able to invoke it. Matched by name prefix rather than the
          // function's own arn: referencing that here is a dependency cycle,
          // and granting it through a separate aws.iam.RolePolicy silently
          // stops working the moment sst recreates the role -- the policy
          // stays bound to the old one while pulumi still believes it
          // exists, which is what took the deployed bot down.
          actions: ["lambda:InvokeFunction"],
          resources: [
            // "BotFunction" is this component's logical name, so the prefix
            // stays put across the random suffix sst regenerates, without
            // widening the grant to every function in the stack
            $interpolate`arn:aws:lambda:${aws.getRegionOutput().name}:${aws.getCallerIdentityOutput().accountId}:function:${$app.name}-${$app.stage}-BotFunction-*`,
          ],
        },
      ],
    });

    return {
      // set this as the request URL under Event Subscriptions
      url: bot.url,
      state: state.name,
    };
  },
});
