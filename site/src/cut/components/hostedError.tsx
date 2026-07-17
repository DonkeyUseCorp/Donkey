import { creditsUrl, NO_CREDITS_MESSAGE } from "@/cut/lib/generate";

/** A hosted-inference error message (chat reply or generation tile). An
 * empty-balance failure reads "No credits left, reload here" with the credits
 * link inline; any other error (or a missing message) renders as plain text.
 * Surfaces inside the chat panel pass `link={false}` — there the composer's
 * credits tab carries the reload link, so the messages stay plain. */
export function HostedErrorText({ error, link = true }: { error?: string; link?: boolean }) {
  if (error === NO_CREDITS_MESSAGE) {
    if (!link) return <>{NO_CREDITS_MESSAGE}</>;
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
