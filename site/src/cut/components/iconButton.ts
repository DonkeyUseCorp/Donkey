/** Small trailing icon control on a light card row or list item (add, menu,
 * copy, dismiss): a filled pill, matching the row's play button, so it reads
 * clearly against the card the moment a hover reveal shows it. Media tiles
 * use the dark `bg-black/45 text-white` scrim pill instead. */
export const cardIconButton =
  "grid size-6 shrink-0 place-items-center rounded-full bg-muted text-foreground transition-all hover:bg-muted-foreground/20";

/** The dark scrim pill for controls floating over media — image/video tiles
 * and the emerald audio pill. */
export const scrimIconButton =
  "grid size-5 shrink-0 place-items-center rounded-full bg-black/45 text-white transition-colors hover:bg-black/65";
