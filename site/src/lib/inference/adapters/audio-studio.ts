import {
  ElevenLabsClient,
  ElevenLabsError,
  type ElevenLabs,
} from "@elevenlabs/elevenlabs-js";

import { elevenLabsModels } from "@/lib/inference/elevenlabs-models";
import { ensureConfigured } from "@/lib/inference/http";
import { toJsonObject, toJsonValue } from "@/lib/inference/json";
import {
  InferenceProviderError,
  type AssetGenerationRequest,
  type AssetGenerationProviderRequest,
  type AssetGenerationProviderResult,
  type GenerationOutputRef,
  type InferenceModality,
  type InferenceModel,
  type InferenceProvider,
  type JsonValue,
} from "@/lib/inference/providers";

type AdapterEnvironment = Record<string, string | undefined>;
type AudioResponsePromise = Promise<ReadableStream<Uint8Array>> & {
  withRawResponse: () => Promise<{
    data: ReadableStream<Uint8Array>;
    rawResponse: { headers: Headers };
  }>;
};

const providerID = "elevenlabs";

// The concrete model the provider bills for in each mode. result.model must always be a real,
// priced model id (never "") so credit pricing can resolve it — an omitted request.model falls
// back to these. All are priced in provider-pricing.ts (elevenLabsCreditPricing).
const defaultAudioModels = {
  music: elevenLabsModels.music,
  sound: "eleven_text_to_sound_v2",
  speech: "eleven_multilingual_v2",
} as const;

export function createAudioAssetProvider(
  environment: AdapterEnvironment = process.env,
  fetcher: typeof fetch = fetch,
): InferenceProvider {
  const apiKey = environment.ELEVENLABS_API_KEY?.trim() ?? "";
  const configured = apiKey.length > 0;
  const client = new ElevenLabsClient({ apiKey, fetch: fetcher });

  async function listModels(modalities: InferenceModality[]) {
    try {
      const remoteModels = await client.models.list();
      return remoteModels
        .flatMap((model) => normalizeAudioModel(model))
        .filter((model) => {
          return model.outputModalities.some((modality) => {
            return modalities.includes(modality);
          });
        });
    } catch (error) {
      throw providerError("Unable to list audio inference models.", error);
    }
  }

  async function generateAsset({
    request,
  }: AssetGenerationProviderRequest): Promise<AssetGenerationProviderResult> {
    ensureConfigured(configured);

    if (request.kind !== "music") {
      throw new InferenceProviderError("Provider does not support this asset kind.", {
        statusCode: 400,
        code: "unsupported_asset_kind",
      });
    }

    const mode = stringParam(request.parameters, "audioMode") ?? "music";
    switch (mode) {
      case "music":
        return createMusic(client, request);
      case "speech":
        return createSpeech(client, request);
      case "sound":
      case "sound_effect":
        return createSound(client, request);
      default:
        throw new InferenceProviderError("Unsupported audio generation mode.", {
          statusCode: 400,
          code: "unsupported_audio_mode",
          details: { mode },
        });
    }
  }

  return {
    id: providerID,
    configured,
    // Music only: generateAsset rejects every other kind, and advertising the
    // generic "audio" capability would make this a fallback match for speech
    // routing (preferredCapabilities ["speech","audio"]) and misroute voiceovers
    // here whenever the speech provider is unconfigured.
    capabilities: ["music"],
    listModels,
    generateAsset,
  };
}

function normalizeAudioModel(value: unknown): InferenceModel[] {
  const json = toJsonObject(value);
  const id = readString(json, "modelId", "model_id");
  if (!id) {
    return [];
  }

  return [
    {
      id,
      name: readString(json, "name") ?? id,
      provider: providerID,
      inputModalities: ["text"],
      outputModalities: ["audio"],
      contextLength: null,
      pricing: null,
      metadata: json,
    },
  ];
}

function createMusic(
  client: ElevenLabsClient,
  request: AssetGenerationRequest,
) {
  const parameters = toJsonObject(request.parameters ?? {});
  const model = request.model?.trim() || defaultAudioModels.music;

  return createAudioResponse(
    model,
    "music",
    "music-1.mp3",
    {
      durationMillis: numberParam(parameters, "music_length_ms", "musicLengthMs"),
    },
    () =>
      client.music.compose({
        ...parameters,
        modelId: model,
        prompt: request.prompt,
      } as ElevenLabs.BodyComposeMusicV1MusicPost),
  );
}

function createSound(
  client: ElevenLabsClient,
  request: AssetGenerationRequest,
) {
  const parameters = toJsonObject(request.parameters ?? {});
  const model = request.model?.trim() || defaultAudioModels.sound;
  const durationSeconds = numberParam(
    parameters,
    "duration_seconds",
    "durationSeconds",
  );

  return createAudioResponse(
    model,
    "sound",
    "sound-1.mp3",
    {
      durationMillis: durationSeconds === undefined
        ? undefined
        : Math.ceil(durationSeconds * 1000),
    },
    () =>
      client.textToSoundEffects.convert({
        ...parameters,
        modelId: model,
        text: request.prompt,
      } as ElevenLabs.CreateSoundEffectRequest),
  );
}

function createSpeech(
  client: ElevenLabsClient,
  request: AssetGenerationRequest,
) {
  const voiceID =
    stringParam(request.inputs, "voiceId") ??
    stringParam(request.inputs, "voice_id") ??
    stringParam(request.parameters, "voiceId") ??
    stringParam(request.parameters, "voice_id");

  if (!voiceID) {
    throw new InferenceProviderError("Speech generation requires a voice id.", {
      statusCode: 400,
      code: "missing_voice_id",
    });
  }

  const parameters = toJsonObject(request.parameters ?? {});
  const model = request.model?.trim() || defaultAudioModels.speech;

  return createAudioResponse(
    model,
    "speech",
    "speech-1.mp3",
    {
      fallbackCharacterCost: request.prompt.length,
    },
    () =>
      client.textToSpeech.convert(voiceID, {
        ...parameters,
        modelId: model,
        text: request.prompt,
      } as ElevenLabs.BodyTextToSpeechFull),
  );
}

async function createAudioResponse(
  model: string,
  mode: string,
  filename: string,
  usageInput: {
    durationMillis?: number;
    fallbackCharacterCost?: number;
  },
  run: () => AudioResponsePromise,
): Promise<AssetGenerationProviderResult> {
  try {
    const { data, rawResponse } = await run().withRawResponse();
    const bytes = Buffer.from(await new Response(data).arrayBuffer());
    const characterCost = rawResponse.headers.get("character-cost");
    const output: GenerationOutputRef = {
      id: "audio-1",
      kind: "audio",
      dataBase64: bytes.toString("base64"),
      contentType: rawResponse.headers.get("content-type") ?? undefined,
      filename,
      byteCount: bytes.byteLength,
      metadata: {
        mode,
        source: "provider-output",
      },
    };

    return {
      provider: providerID,
      model,
      status: "completed",
      providerGenerationId: rawResponse.headers.get("song-id") ?? undefined,
      outputs: [output],
      usage: audioUsage({
        characterCost,
        ...usageInput,
      }),
      metadata: {
        provider: providerID,
        mode,
        outputCount: "1",
      },
    };
  } catch (error) {
    throw providerError("Audio generation failed.", error);
  }
}

function providerError(message: string, error: unknown) {
  if (error instanceof ElevenLabsError) {
    return new InferenceProviderError(message, {
      statusCode: error.statusCode ?? 502,
      details: error.body ? toJsonValue(error.body) : null,
    });
  }

  return new InferenceProviderError(message, {
    details: {
      message: error instanceof Error ? error.message : "Unknown error",
    },
  });
}

function audioUsage(input: {
  characterCost: string | null;
  durationMillis?: number;
  fallbackCharacterCost?: number;
}): JsonValue | undefined {
  const usage: Record<string, JsonValue> = {};
  let hasCharacterUsage = false;
  if (input.characterCost?.trim()) {
    usage.characterCost = input.characterCost.trim();
    hasCharacterUsage = true;
  } else if (
    input.fallbackCharacterCost !== undefined &&
    Number.isSafeInteger(input.fallbackCharacterCost) &&
    input.fallbackCharacterCost > 0
  ) {
    usage.characterCost = input.fallbackCharacterCost;
    hasCharacterUsage = true;
  }

  if (
    !hasCharacterUsage &&
    input.durationMillis !== undefined &&
    Number.isSafeInteger(input.durationMillis) &&
    input.durationMillis > 0
  ) {
    usage.durationMillis = input.durationMillis;
  }

  return Object.keys(usage).length > 0 ? usage : undefined;
}

function readString(value: Record<string, JsonValue>, ...keys: string[]) {
  for (const key of keys) {
    const candidate = value[key];
    if (typeof candidate === "string" && candidate.trim()) {
      return candidate.trim();
    }
  }

  return undefined;
}

function numberParam(value: Record<string, unknown> | undefined, ...keys: string[]) {
  for (const key of keys) {
    const candidate = value?.[key];
    if (typeof candidate === "number" && Number.isFinite(candidate)) {
      return candidate;
    }
    if (typeof candidate === "string" && candidate.trim()) {
      const parsed = Number(candidate);
      if (Number.isFinite(parsed)) {
        return parsed;
      }
    }
  }

  return undefined;
}

function stringParam(value: Record<string, unknown> | undefined, ...keys: string[]) {
  for (const key of keys) {
    const candidate = value?.[key];
    if (typeof candidate === "string" && candidate.trim()) {
      return candidate.trim();
    }
  }

  return undefined;
}
