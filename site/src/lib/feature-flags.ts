// The registry of account feature flags. A flag ships here first; the account
// settings page renders this list and the API accepts only these ids.

export type AccountFeatureFlag = {
  id: string;
  title: string;
  description: string;
};

export const ACCOUNT_FEATURE_FLAGS: AccountFeatureFlag[] = [
  {
    id: "cut-web-mode",
    title: "Cloud mode (beta)",
    description:
      "Edit in any browser on any OS with no install: projects stored in the cloud, exports rendered by a cloud worker. The Mac app keeps running everything locally.",
  },
];

export const isKnownFeatureFlag = (id: string) =>
  ACCOUNT_FEATURE_FLAGS.some((f) => f.id === id);
