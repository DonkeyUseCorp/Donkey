// Public Donkey Vision API contract for POST /api/inference/vision.
// Keep this in sync with src/lib/inference/vision/schema.ts.

export const API_ENDPOINT = {
  method: "POST",
  path: "/api/inference/vision",
  host: "https://donkeyuse.com",
} as const;

export type CodeLanguage = {
  key: string;
  label: string;
  code: string;
};

const url = `${API_ENDPOINT.host}${API_ENDPOINT.path}`;

export const CODE_SAMPLES: CodeLanguage[] = [
  {
    key: "typescript",
    label: "TypeScript",
    code: `const res = await fetch("${url}", {
  method: "POST",
  headers: {
    Authorization: \`Bearer \${process.env.DONKEY_API_KEY}\`,
    "Content-Type": "application/json",
  },
  body: JSON.stringify({
    // base64 png/jpeg/webp, no "data:" prefix
    image: screenshotBase64,
    instruction: "click the play button",
    returnElements: true,
  }),
});

const { target } = await res.json();
console.log(target.point); // { x, y } — ready to click`,
  },
  {
    key: "python",
    label: "Python",
    code: `import os, requests

res = requests.post(
    "${url}",
    headers={"Authorization": f"Bearer {os.environ['DONKEY_API_KEY']}"},
    json={
        # base64 png/jpeg/webp, no "data:" prefix
        "image": screenshot_base64,
        "instruction": "click the play button",
        "returnElements": True,
    },
)

target = res.json()["target"]
print(target["point"])  # { x, y } — ready to click`,
  },
  {
    key: "swift",
    label: "Swift",
    code: `var request = URLRequest(url: URL(string: "${url}")!)
request.httpMethod = "POST"
request.setValue("Bearer \\(apiKey)", forHTTPHeaderField: "Authorization")
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.httpBody = try JSONSerialization.data(withJSONObject: [
    // base64 png/jpeg/webp, no "data:" prefix
    "image": screenshotBase64,
    "instruction": "click the play button",
    "returnElements": true,
])

let (data, _) = try await URLSession.shared.data(for: request)
let result = try JSONDecoder().decode(VisionResponse.self, from: data)
print(result.target?.point) // { x, y } — ready to click`,
  },
];

export const RESPONSE_SAMPLE = `{
  "image": { "width": 1440, "height": 900 },
  "elements": [
    {
      "id": "a92kfq",
      "label": "Play",
      "kind": "button",
      "interactive": true,
      "box": { "x": 618, "y": 816, "width": 42, "height": 42 },
      "point": { "x": 639, "y": 837 },
      "confidence": 0.82
    }
  ],
  "target": {
    "elementId": "a92kfq",
    "label": "Play",
    "kind": "button",
    "box": { "x": 618, "y": 816, "width": 42, "height": 42 },
    "point": { "x": 639, "y": 837 },
    "confidence": 0.91
  },
  "alternates": [],
  "model": "gemini-3.1-flash-lite"
}`;

export type ApiField = {
  name: string;
  type: string;
  required?: boolean;
  description: string;
};

export const BODY_PARAMS: ApiField[] = [
  {
    name: "image",
    type: "string",
    required: true,
    description:
      "Your screenshot as base64 text (PNG, JPEG, or WebP). For the best results, make it a JPEG at quality 0.8 and shrink it so the longest side is 1568 pixels.",
  },
  {
    name: "instruction",
    type: "string",
    description:
      "Tell it what to click in plain words, like “click the play button”. Then you also get back the one spot to click.",
  },
  {
    name: "model",
    type: "string",
    description:
      "Which model picks the spot to click. Use gemini-3.5-flash or gemini-3.1-flash-lite. If you don’t pick, it uses gemini-3.1-flash-lite.",
  },
  {
    name: "returnElements",
    type: "boolean",
    description:
      "Set to true to get the full list of things it found. It’s on by default, and off when you send an instruction.",
  },
];

export const RESPONSE_FIELDS: ApiField[] = [
  {
    name: "image",
    type: "object",
    description: "How big your screenshot is, in pixels: { width, height }.",
  },
  {
    name: "elements",
    type: "array",
    description:
      "Everything it found. Each one has an id, label, kind, interactive, box, point, and confidence. Left out when returnElements is false.",
  },
  {
    name: "target",
    type: "object | null",
    description:
      "The one thing to click for your instruction, with its box and click point. Only here when you send an instruction.",
  },
  {
    name: "alternates",
    type: "array",
    description: "Other things that might match your instruction, best ones first.",
  },
  {
    name: "model",
    type: "string",
    description: "The model that picked the spot to click.",
  },
];
