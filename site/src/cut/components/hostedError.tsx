import { creditsUrl, NO_CREDITS_MESSAGE } from "@/cut/lib/generate";

/** A hosted-inference error message (chat reply or generation tile). An
 * empty-balance failure reads "No credits left, reload here" with the credits
 * link inline; any other error (or a missing message) renders as plain text. */
export function HostedErrorText({ error }: { error?: string }) {
  if (error === NO_CREDITS_MESSAGE) {
    return (
      <>
        No credits left,{" "}
        <a
          className="font-medium underline hover:no-underline"
          href={creditsUrl()}
          target="_blank"
          rel="noreferrer"
        >
          reload here
        </a>
      </>
    );
  }
  return <>{error ?? "Failed."}</>;
}
