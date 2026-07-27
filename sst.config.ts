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
      ],
    });

    // bolt's lazy listeners ack inside slack's 3s window and then re-invoke
    // this same function to run the eval. Granted separately rather than via
    // `permissions` because the function can't reference its own arn without
    // a dependency cycle.
    new aws.iam.RolePolicy("BotSelfInvoke", {
      role: bot.nodes.role.name,
      policy: bot.nodes.function.arn.apply((arn) =>
        JSON.stringify({
          Version: "2012-10-17",
          Statement: [
            { Effect: "Allow", Action: "lambda:InvokeFunction", Resource: arn },
          ],
        }),
      ),
    });

    return {
      // set this as the request URL under Event Subscriptions
      url: bot.url,
      state: state.name,
    };
  },
});
