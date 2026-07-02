// Static content for the media-generation showcase: example images and videos
// Donkey can make, grouped by creative category. Each item carries the exact
// generation prompt so a visitor can copy it and paste it into Donkey.
//
// Assets live under public/media-showcase/ and were generated from each item's
// prompt (Gemini image for images, Veo for videos); video tiles use an
// extracted poster frame as their thumbnail.

export type MediaKind = "image" | "video";

export type MediaCategory =
  | "Image"
  | "Video"
  | "Motion graphics"
  | "UGC & Ads"
  | "Animation & Illustration";

export type MediaAspect = "portrait" | "landscape" | "square";

export type MediaShowcaseItem = {
  id: string;
  title: string;
  kind: MediaKind;
  category: MediaCategory;
  // The copyable generation prompt.
  prompt: string;
  aspect: MediaAspect;
  // Short capability tags shown in the detail dialog (model, aspect, length…).
  settings?: string[];
  // Grid tile image (poster frame for videos).
  thumbnailSrc: string;
  // Full media revealed in the detail dialog.
  mediaSrc: string;
};

export const mediaCategories: MediaCategory[] = [
  "Image",
  "Video",
  "Motion graphics",
  "UGC & Ads",
  "Animation & Illustration",
];

export const mediaShowcaseItems: MediaShowcaseItem[] = [
  // ── Image ──────────────────────────────────────────────────────────────
  {
    id: "neon-koi-pond",
    title: "Neon koi pond, top-down",
    kind: "image",
    category: "Image",
    prompt:
      "A top-down view of koi fish gliding through a dark pond, bioluminescent neon fins, ripples catching moonlight, ultra-detailed, cinematic lighting.",
    aspect: "square",
    settings: ["Gemini image", "1:1"],
    thumbnailSrc: "/media-showcase/neon-koi-pond.webp",
    mediaSrc: "/media-showcase/neon-koi-pond.webp",
  },
  {
    id: "perfume-hero",
    title: "Perfume bottle product hero",
    kind: "image",
    category: "Image",
    prompt:
      "Studio product shot of a frosted glass perfume bottle on wet black stone, soft rim light, scattered dewdrops, luxury advertising aesthetic, 85mm lens.",
    aspect: "portrait",
    settings: ["Gemini image", "4:5"],
    thumbnailSrc: "/media-showcase/perfume-hero.webp",
    mediaSrc: "/media-showcase/perfume-hero.webp",
  },
  {
    id: "alpine-lake-dawn",
    title: "Alpine lake at dawn",
    kind: "image",
    category: "Image",
    prompt:
      "Long-shot scenic photograph of a mirror-still alpine lake at dawn, dramatic sky, wide-angle, HDR, vivid natural color, everything in razor-sharp focus.",
    aspect: "landscape",
    settings: ["Gemini image", "16:9"],
    thumbnailSrc: "/media-showcase/alpine-lake-dawn.webp",
    mediaSrc: "/media-showcase/alpine-lake-dawn.webp",
  },
  {
    id: "floating-sneaker-catalog",
    title: "Floating sneaker, catalog shot",
    kind: "image",
    category: "Image",
    prompt:
      "Professional product photo of a white leather sneaker floating midair, intricate stitching, seamless pale-grey backdrop, crisp studio lighting, front view.",
    aspect: "square",
    settings: ["Gemini image", "1:1"],
    thumbnailSrc: "/media-showcase/floating-sneaker-catalog.webp",
    mediaSrc: "/media-showcase/floating-sneaker-catalog.webp",
  },
  {
    id: "reading-nook-interior",
    title: "Cozy reading nook interior",
    kind: "image",
    category: "Image",
    prompt:
      "Interior design photo of a cozy reading nook with a worn leather armchair, floor-to-ceiling bookshelves, warm afternoon light through a bay window, architectural-digest style.",
    aspect: "landscape",
    settings: ["Gemini image", "3:2"],
    thumbnailSrc: "/media-showcase/reading-nook-interior.webp",
    mediaSrc: "/media-showcase/reading-nook-interior.webp",
  },
  {
    id: "fisherman-portrait",
    title: "Weathered fisherman portrait",
    kind: "image",
    category: "Image",
    prompt:
      "Close-up portrait of an older fisherman with a weathered face and kind eyes, soft window light, shallow depth of field, photorealistic, natural skin texture.",
    aspect: "portrait",
    settings: ["Gemini image", "4:5"],
    thumbnailSrc: "/media-showcase/fisherman-portrait.webp",
    mediaSrc: "/media-showcase/fisherman-portrait.webp",
  },
  {
    id: "ramen-overhead",
    title: "Steaming ramen, overhead",
    kind: "image",
    category: "Image",
    prompt:
      "Overhead food photograph of a steaming bowl of tonkotsu ramen, glossy broth, soft-boiled egg, chopsticks lifting noodles, moody dark table, appetizing studio light.",
    aspect: "square",
    settings: ["Gemini image", "1:1"],
    thumbnailSrc: "/media-showcase/ramen-overhead.webp",
    mediaSrc: "/media-showcase/ramen-overhead.webp",
  },
  {
    id: "cyberpunk-alley",
    title: "Cyberpunk alley in the rain",
    kind: "image",
    category: "Image",
    prompt:
      "Cyberpunk city alley at night, dense neon signage reflected in rain puddles, drifting steam, distant flying cars, cinematic teal-and-magenta grade, sharp focus.",
    aspect: "landscape",
    settings: ["Gemini image", "16:9"],
    thumbnailSrc: "/media-showcase/cyberpunk-alley.webp",
    mediaSrc: "/media-showcase/cyberpunk-alley.webp",
  },
  {
    id: "desert-dunes-abstract",
    title: "Desert dunes at sunset",
    kind: "image",
    category: "Image",
    prompt:
      "Minimal abstract photograph of rippled desert dunes at sunset, long shadows carving graphic curves, warm amber palette, fine sand texture, telephoto compression.",
    aspect: "landscape",
    settings: ["Gemini image", "16:9"],
    thumbnailSrc: "/media-showcase/desert-dunes-abstract.webp",
    mediaSrc: "/media-showcase/desert-dunes-abstract.webp",
  },
  {
    id: "greenhouse-interior",
    title: "Glass greenhouse interior",
    kind: "image",
    category: "Image",
    prompt:
      "Botanical photograph inside a Victorian glass greenhouse, lush layered tropical plants, soft diffused daylight through fogged panes, gentle green palette, editorial style.",
    aspect: "landscape",
    settings: ["Gemini image", "3:2"],
    thumbnailSrc: "/media-showcase/greenhouse-interior.webp",
    mediaSrc: "/media-showcase/greenhouse-interior.webp",
  },
  {
    id: "golden-retriever-studio",
    title: "Golden retriever studio portrait",
    kind: "image",
    category: "Image",
    prompt:
      "Studio portrait of a golden retriever mid head-tilt, seamless warm beige backdrop, crisp catchlights in the eyes, fur detail razor sharp, joyful expression.",
    aspect: "square",
    settings: ["Gemini image", "1:1"],
    thumbnailSrc: "/media-showcase/golden-retriever-studio.webp",
    mediaSrc: "/media-showcase/golden-retriever-studio.webp",
  },
  {
    id: "citrus-splash-macro",
    title: "Citrus splash macro",
    kind: "image",
    category: "Image",
    prompt:
      "High-speed macro photograph of a lime slice plunging into sparkling water, frozen splash crown, rising bubbles, backlit vivid green, pin-sharp droplets.",
    aspect: "square",
    settings: ["Gemini image", "1:1"],
    thumbnailSrc: "/media-showcase/citrus-splash-macro.webp",
    mediaSrc: "/media-showcase/citrus-splash-macro.webp",
  },
  {
    id: "macaron-tower-pastel",
    title: "Pastel macaron tower",
    kind: "image",
    category: "Image",
    prompt:
      "Food photograph of a tall macaron tower in soft pastels on a marble counter, shallow depth of field, airy high-key light, patisserie editorial styling.",
    aspect: "portrait",
    settings: ["Gemini image", "4:5"],
    thumbnailSrc: "/media-showcase/macaron-tower-pastel.webp",
    mediaSrc: "/media-showcase/macaron-tower-pastel.webp",
  },
  {
    id: "surfer-barrel-wave",
    title: "Surfer inside the barrel",
    kind: "image",
    category: "Image",
    prompt:
      "Action photograph of a surfer crouched inside a glassy turquoise barrel wave, spray backlit by low sun, water texture frozen, shot from the shoulder of the wave.",
    aspect: "portrait",
    settings: ["Gemini image", "4:5"],
    thumbnailSrc: "/media-showcase/surfer-barrel-wave.webp",
    mediaSrc: "/media-showcase/surfer-barrel-wave.webp",
  },
  {
    id: "northern-lights-cabin",
    title: "Northern lights over a cabin",
    kind: "image",
    category: "Image",
    prompt:
      "Night landscape of a lone snow-covered cabin with warm windows under a swirling green aurora, star field, long-exposure feel, deep blue and emerald palette.",
    aspect: "landscape",
    settings: ["Gemini image", "3:2"],
    thumbnailSrc: "/media-showcase/northern-lights-cabin.webp",
    mediaSrc: "/media-showcase/northern-lights-cabin.webp",
  },
  {
    id: "vintage-roadster-coast",
    title: "Vintage roadster on a coast road",
    kind: "image",
    category: "Image",
    prompt:
      "Cinematic photograph of a cream vintage roadster parked on a winding coastal road at golden hour, ocean haze below, chrome catching the sun, travel-editorial mood.",
    aspect: "landscape",
    settings: ["Gemini image", "16:9"],
    thumbnailSrc: "/media-showcase/vintage-roadster-coast.webp",
    mediaSrc: "/media-showcase/vintage-roadster-coast.webp",
  },

  // ── Video ──────────────────────────────────────────────────────────────
  {
    id: "coastal-drone",
    title: "Drone over coastal cliffs",
    kind: "video",
    category: "Video",
    prompt:
      "Aerial drone shot sweeping over rugged coastal cliffs at golden hour, waves crashing far below, cinematic color grade, smooth continuous motion.",
    aspect: "landscape",
    settings: ["Veo", "16:9", "8s"],
    thumbnailSrc: "/media-showcase/coastal-drone-thumb.webp",
    mediaSrc: "/media-showcase/coastal-drone.mp4",
  },
  {
    id: "rainy-neon-push",
    title: "Rainy neon street, slow push-in",
    kind: "video",
    category: "Video",
    prompt:
      "Slow cinematic push-in down a rainy neon-lit Tokyo alley at night, reflections shimmering on wet pavement, shallow depth of field, moody atmosphere.",
    aspect: "landscape",
    settings: ["Veo", "16:9", "6s"],
    thumbnailSrc: "/media-showcase/rainy-neon-push-thumb.webp",
    mediaSrc: "/media-showcase/rainy-neon-push.mp4",
  },
  {
    id: "floating-islands-flythrough",
    title: "Floating islands flythrough",
    kind: "video",
    category: "Video",
    prompt:
      "Cinematic flythrough of floating fantasy islands with waterfalls cascading into clouds, golden magic-hour light, sweeping camera, epic sense of scale.",
    aspect: "landscape",
    settings: ["Veo", "16:9", "8s"],
    thumbnailSrc: "/media-showcase/floating-islands-flythrough-thumb.webp",
    mediaSrc: "/media-showcase/floating-islands-flythrough.mp4",
  },
  {
    id: "pourover-slowmo",
    title: "Pour-over coffee, slow motion",
    kind: "video",
    category: "Video",
    prompt:
      "Slow-motion close-up of a barista pouring a spiral of steaming water over a pour-over, rising steam, warm cafe bokeh, shallow depth of field.",
    aspect: "landscape",
    settings: ["Veo", "16:9", "5s"],
    thumbnailSrc: "/media-showcase/pourover-slowmo-thumb.webp",
    mediaSrc: "/media-showcase/pourover-slowmo.mp4",
  },
  {
    id: "forest-walk-pov",
    title: "Forest trail POV walk",
    kind: "video",
    category: "Video",
    prompt:
      "First-person walk along a mossy forest trail, dappled sunlight flickering through the canopy, gentle handheld motion, birds crossing the frame.",
    aspect: "landscape",
    settings: ["Veo", "16:9", "6s"],
    thumbnailSrc: "/media-showcase/forest-walk-pov-thumb.webp",
    mediaSrc: "/media-showcase/forest-walk-pov.mp4",
  },
  {
    id: "city-sunset-timelapse",
    title: "City sunset-to-night timelapse",
    kind: "video",
    category: "Video",
    prompt:
      "Timelapse of a city skyline shifting from sunset to night, clouds streaking overhead, windows lighting up one by one, smooth exposure ramp.",
    aspect: "landscape",
    settings: ["Veo", "16:9", "8s"],
    thumbnailSrc: "/media-showcase/city-sunset-timelapse-thumb.webp",
    mediaSrc: "/media-showcase/city-sunset-timelapse.mp4",
  },
  {
    id: "freediver-sunbeams",
    title: "Free-diver into sunbeams",
    kind: "video",
    category: "Video",
    prompt:
      "Underwater shot following a free-diver descending into shafts of sunlight, bubbles rising, deep blue gradient, serene slow motion.",
    aspect: "portrait",
    settings: ["Veo", "9:16", "6s"],
    thumbnailSrc: "/media-showcase/freediver-sunbeams-thumb.webp",
    mediaSrc: "/media-showcase/freediver-sunbeams.mp4",
  },
  {
    id: "desert-rally-chase",
    title: "Desert rally car chase",
    kind: "video",
    category: "Video",
    prompt:
      "Cinematic tracking shot of a rally car tearing across a desert flat, huge dust plume trailing, low sun flare, dynamic camera keeping pace.",
    aspect: "landscape",
    settings: ["Veo", "16:9", "8s"],
    thumbnailSrc: "/media-showcase/desert-rally-chase-thumb.webp",
    mediaSrc: "/media-showcase/desert-rally-chase.mp4",
  },

  // ── Motion graphics ──────────────────────────────────────────────────────
  {
    id: "logo-line-reveal",
    title: "Looping logo line reveal",
    kind: "video",
    category: "Motion graphics",
    prompt:
      "A minimal logo reveal: a coral mark draws on with a single continuous line while a soft gradient background morphs slowly, seamless loop, clean and modern.",
    aspect: "landscape",
    settings: ["Veo", "16:9", "Loop"],
    thumbnailSrc: "/media-showcase/logo-line-reveal-thumb.webp",
    mediaSrc: "/media-showcase/logo-line-reveal.mp4",
  },
  {
    id: "glass-prism-loop",
    title: "Iridescent glass prism",
    kind: "video",
    category: "Motion graphics",
    prompt:
      "Macro 3D render of an iridescent glass prism rotating slowly, rainbow caustics sweeping across a soft grey studio backdrop, crisp refractions, seamless loop, no text or lettering.",
    aspect: "landscape",
    settings: ["Veo", "16:9", "Loop"],
    thumbnailSrc: "/media-showcase/glass-prism-loop-thumb.webp",
    mediaSrc: "/media-showcase/glass-prism-loop.mp4",
  },
  {
    id: "silk-ribbon-loop",
    title: "Silk ribbons in flow",
    kind: "video",
    category: "Motion graphics",
    prompt:
      "Abstract 3D render of silk ribbons flowing and rippling in slow motion, coral and cream palette, soft studio lighting, gentle depth of field, seamless loop, no text or lettering.",
    aspect: "landscape",
    settings: ["Veo", "16:9", "Loop"],
    thumbnailSrc: "/media-showcase/silk-ribbon-loop-thumb.webp",
    mediaSrc: "/media-showcase/silk-ribbon-loop.mp4",
  },
  {
    id: "gradient-blob-loop",
    title: "Morphing gradient blob",
    kind: "video",
    category: "Motion graphics",
    prompt:
      "Seamless loop of a soft gradient blob slowly morphing between organic shapes, coral-to-peach palette, smooth easing, minimal and calming.",
    aspect: "landscape",
    settings: ["Veo", "16:9", "Loop"],
    thumbnailSrc: "/media-showcase/gradient-blob-loop-thumb.webp",
    mediaSrc: "/media-showcase/gradient-blob-loop.mp4",
  },
  {
    id: "icon-system-build",
    title: "Icon set draws on",
    kind: "video",
    category: "Motion graphics",
    prompt:
      "Motion-graphics sequence where a row of line icons draws on one by one and settles into place, clean ink strokes on white, snappy staggered timing.",
    aspect: "landscape",
    settings: ["Veo", "16:9", "5s"],
    thumbnailSrc: "/media-showcase/icon-system-build-thumb.webp",
    mediaSrc: "/media-showcase/icon-system-build.mp4",
  },
  {
    id: "particle-bloom",
    title: "Golden particle bloom",
    kind: "video",
    category: "Motion graphics",
    prompt:
      "Golden particles swirling and blooming into a glowing sphere on a deep charcoal background, elegant slow motion, cinematic depth, seamless loop, no text or lettering.",
    aspect: "landscape",
    settings: ["Veo", "16:9", "Loop"],
    thumbnailSrc: "/media-showcase/particle-bloom-thumb.webp",
    mediaSrc: "/media-showcase/particle-bloom.mp4",
  },
  {
    id: "paper-waves-parallax",
    title: "Paper waves in parallax",
    kind: "video",
    category: "Motion graphics",
    prompt:
      "Layered paper-cutout ocean waves drifting in gentle parallax, pastel gradient palette, soft drop shadows, calm rhythmic motion, seamless loop, no text or lettering.",
    aspect: "landscape",
    settings: ["Veo", "16:9", "Loop"],
    thumbnailSrc: "/media-showcase/paper-waves-parallax-thumb.webp",
    mediaSrc: "/media-showcase/paper-waves-parallax.mp4",
  },
  {
    id: "shape-wipe-transitions",
    title: "Shape-wipe transition pack",
    kind: "video",
    category: "Motion graphics",
    prompt:
      "A pack of smooth shape-wipe transitions revealing the next scene, coral shapes sliding across a cream frame, punchy modern rhythm.",
    aspect: "landscape",
    settings: ["Veo", "16:9", "5s"],
    thumbnailSrc: "/media-showcase/shape-wipe-transitions-thumb.webp",
    mediaSrc: "/media-showcase/shape-wipe-transitions.mp4",
  },

  // ── UGC & Ads ────────────────────────────────────────────────────────────
  {
    id: "unboxing-selfie",
    title: "Unboxing selfie clip",
    kind: "video",
    category: "UGC & Ads",
    prompt:
      "Vertical UGC-style selfie video of a creator unboxing a skincare product by a bright window, natural handheld motion, authentic and upbeat tone.",
    aspect: "portrait",
    settings: ["Veo", "9:16", "6s"],
    thumbnailSrc: "/media-showcase/unboxing-selfie-thumb.webp",
    mediaSrc: "/media-showcase/unboxing-selfie.mp4",
  },
  {
    id: "sneaker-hover-ad",
    title: "Sneaker hover, vertical ad",
    kind: "video",
    category: "UGC & Ads",
    prompt:
      "Vertical product ad: a running sneaker slowly rotating and hovering over concrete, drifting dust particles, punchy directional lighting, energetic quick cuts.",
    aspect: "portrait",
    settings: ["Veo", "9:16", "5s"],
    thumbnailSrc: "/media-showcase/sneaker-hover-ad-thumb.webp",
    mediaSrc: "/media-showcase/sneaker-hover-ad.mp4",
  },
  {
    id: "serum-testimonial",
    title: "Skincare testimonial",
    kind: "video",
    category: "UGC & Ads",
    prompt:
      "Vertical talking-head UGC clip of a creator raving about a serum at a bathroom counter, natural handheld feel, warm morning light, honest delivery.",
    aspect: "portrait",
    settings: ["Veo", "9:16", "8s"],
    thumbnailSrc: "/media-showcase/serum-testimonial-thumb.webp",
    mediaSrc: "/media-showcase/serum-testimonial.mp4",
  },
  {
    id: "grwm-morning",
    title: "Get-ready-with-me clip",
    kind: "video",
    category: "UGC & Ads",
    prompt:
      "Vertical GRWM-style clip of someone getting ready in a sunlit bedroom, quick natural jump cuts, phone-camera aesthetic, casual upbeat energy.",
    aspect: "portrait",
    settings: ["Veo", "9:16", "6s"],
    thumbnailSrc: "/media-showcase/grwm-morning-thumb.webp",
    mediaSrc: "/media-showcase/grwm-morning.mp4",
  },
  {
    id: "burger-hero-ad",
    title: "Burger build hero ad",
    kind: "video",
    category: "UGC & Ads",
    prompt:
      "Vertical product ad: a burger assembling in mid-air layer by layer, sesame bun landing on top, dramatic macro, punchy fast cuts, mouth-watering appeal.",
    aspect: "portrait",
    settings: ["Veo", "9:16", "5s"],
    thumbnailSrc: "/media-showcase/burger-hero-ad-thumb.webp",
    mediaSrc: "/media-showcase/burger-hero-ad.mp4",
  },
  {
    id: "app-demo-in-hand",
    title: "App demo, screen in hand",
    kind: "video",
    category: "UGC & Ads",
    prompt:
      "Vertical UGC clip of hands scrolling a mobile app in a cozy cafe, over-the-shoulder framing, tap interactions highlighted, natural ambient feel.",
    aspect: "portrait",
    settings: ["Veo", "9:16", "6s"],
    thumbnailSrc: "/media-showcase/app-demo-in-hand-thumb.webp",
    mediaSrc: "/media-showcase/app-demo-in-hand.mp4",
  },
  {
    id: "matcha-pour-ad",
    title: "Matcha pour, vertical ad",
    kind: "video",
    category: "UGC & Ads",
    prompt:
      "Vertical product ad: slow-motion pour of vivid green matcha over milk and ice in a tall glass, swirling clouds of color, bright airy light, macro condensation detail, no on-screen text.",
    aspect: "portrait",
    settings: ["Veo", "9:16", "6s"],
    thumbnailSrc: "/media-showcase/matcha-pour-ad-thumb.webp",
    mediaSrc: "/media-showcase/matcha-pour-ad.mp4",
  },
  {
    id: "candle-cozy-ad",
    title: "Candle cozy lifestyle ad",
    kind: "video",
    category: "UGC & Ads",
    prompt:
      "Vertical lifestyle ad for a scented candle: a match strike, the flame catching, a cozy blanket and book nearby, warm flickering light, calm intimate mood.",
    aspect: "portrait",
    settings: ["Veo", "9:16", "5s"],
    thumbnailSrc: "/media-showcase/candle-cozy-ad-thumb.webp",
    mediaSrc: "/media-showcase/candle-cozy-ad.mp4",
  },

  // ── Animation & Illustration ─────────────────────────────────────────────
  {
    id: "storybook-fox",
    title: "Storybook fox in autumn",
    kind: "image",
    category: "Animation & Illustration",
    prompt:
      "Children's storybook illustration of a small fox walking through an autumn forest, watercolor textures, warm palette, gentle paper grain.",
    aspect: "portrait",
    settings: ["Gemini image", "3:4"],
    thumbnailSrc: "/media-showcase/storybook-fox.webp",
    mediaSrc: "/media-showcase/storybook-fox.webp",
  },
  {
    id: "anime-rooftop",
    title: "Anime rooftop at dusk",
    kind: "image",
    category: "Animation & Illustration",
    prompt:
      "Anime-style scene of a teenager standing on a school rooftop at dusk, vast glowing cumulus clouds, warm lens flare, crisp cel shading, quiet skyline below, high detail, no text or lettering.",
    aspect: "landscape",
    settings: ["Gemini image", "16:9"],
    thumbnailSrc: "/media-showcase/anime-rooftop.webp",
    mediaSrc: "/media-showcase/anime-rooftop.webp",
  },
  {
    id: "claymation-bee",
    title: "Claymation bee character",
    kind: "image",
    category: "Animation & Illustration",
    prompt:
      "Claymation-style friendly bumblebee mascot standing on a seamless cream backdrop, soft studio lighting, tactile fingerprints in the clay, cheerful expression, no text or lettering.",
    aspect: "square",
    settings: ["Gemini image", "1:1"],
    thumbnailSrc: "/media-showcase/claymation-bee.webp",
    mediaSrc: "/media-showcase/claymation-bee.webp",
  },
  {
    id: "watercolor-seaside-town",
    title: "Watercolor seaside town",
    kind: "image",
    category: "Animation & Illustration",
    prompt:
      "Loose watercolor painting of a pastel seaside town, wet-on-wet washes, soft blooms of color, gentle paper texture, tranquil and airy.",
    aspect: "portrait",
    settings: ["Gemini image", "3:4"],
    thumbnailSrc: "/media-showcase/watercolor-seaside-town.webp",
    mediaSrc: "/media-showcase/watercolor-seaside-town.webp",
  },
  {
    id: "pixel-forest-town",
    title: "Pixel-art forest town",
    kind: "image",
    category: "Animation & Illustration",
    prompt:
      "16-bit pixel-art scene of a cozy forest town at dusk, glowing lantern windows, layered parallax trees, retro game palette, crisp clean pixels.",
    aspect: "landscape",
    settings: ["Gemini image", "16:9"],
    thumbnailSrc: "/media-showcase/pixel-forest-town.webp",
    mediaSrc: "/media-showcase/pixel-forest-town.webp",
  },
  {
    id: "iso-coffee-shop",
    title: "Isometric coffee shop",
    kind: "image",
    category: "Animation & Illustration",
    prompt:
      "Isometric 3D render of a tiny cozy coffee-shop cutaway, warm interior glow, hand-props on every shelf, pastel palette, soft shadows, C4D style.",
    aspect: "square",
    settings: ["Gemini image", "1:1"],
    thumbnailSrc: "/media-showcase/iso-coffee-shop.webp",
    mediaSrc: "/media-showcase/iso-coffee-shop.webp",
  },
  {
    id: "ukiyoe-fox-bridge",
    title: "Ukiyo-e fox spirit",
    kind: "image",
    category: "Animation & Illustration",
    prompt:
      "Ukiyo-e woodblock print of a fox spirit crossing a moonlit bridge, traditional Japanese linework, muted indigo and cream, textured paper grain.",
    aspect: "landscape",
    settings: ["Gemini image", "16:9"],
    thumbnailSrc: "/media-showcase/ukiyoe-fox-bridge.webp",
    mediaSrc: "/media-showcase/ukiyoe-fox-bridge.webp",
  },
  {
    id: "lineart-monstera",
    title: "Single-line botanical",
    kind: "image",
    category: "Animation & Illustration",
    prompt:
      "Minimal single-line-art illustration of a monstera plant, one clean continuous ink stroke, generous negative space, elegant and modern, white background.",
    aspect: "portrait",
    settings: ["Gemini image", "3:4"],
    thumbnailSrc: "/media-showcase/lineart-monstera.webp",
    mediaSrc: "/media-showcase/lineart-monstera.webp",
  },
  {
    id: "popart-astronaut",
    title: "Pop-art comic panel",
    kind: "image",
    category: "Animation & Illustration",
    prompt:
      "Pop-art comic panel of a winking astronaut, bold Ben-Day dots, thick outlines, punchy primary colors, retro screen-print texture.",
    aspect: "square",
    settings: ["Gemini image", "1:1"],
    thumbnailSrc: "/media-showcase/popart-astronaut.webp",
    mediaSrc: "/media-showcase/popart-astronaut.webp",
  },
  {
    id: "pixel-knight-walk",
    title: "Pixel knight walk cycle",
    kind: "video",
    category: "Animation & Illustration",
    prompt:
      "Looping pixel-art walk cycle of a little knight strolling across the frame, retro game animation, crisp sprite work, seamless loop.",
    aspect: "landscape",
    settings: ["Veo", "16:9", "Loop"],
    thumbnailSrc: "/media-showcase/pixel-knight-walk-thumb.webp",
    mediaSrc: "/media-showcase/pixel-knight-walk.mp4",
  },
];

// Items in a single category keep their authored order. The "All" view
// round-robins across categories so a truncated homepage teaser still shows a
// spread of every category rather than one category's block.
export function getItemsByCategory(
  category: MediaCategory | "All",
): MediaShowcaseItem[] {
  if (category !== "All") {
    return mediaShowcaseItems.filter((item) => item.category === category);
  }

  const byCategory = mediaCategories.map((c) =>
    mediaShowcaseItems.filter((item) => item.category === c),
  );
  const interleaved: MediaShowcaseItem[] = [];
  const longest = Math.max(...byCategory.map((group) => group.length));
  for (let index = 0; index < longest; index += 1) {
    for (const group of byCategory) {
      const item = group[index];
      if (item) interleaved.push(item);
    }
  }
  return interleaved;
}
