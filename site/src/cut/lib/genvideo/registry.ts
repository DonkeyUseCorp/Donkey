/**
 * The model registry — how models are swapped in and out.
 *
 * Each capability role has a slot; adapters register themselves into it under a
 * stable id. A `ModelSuite` is then a selection of one id per role, and
 * `buildSuite` resolves that selection to live adapters. Swapping a model is
 * passing a different id; an eval compares two selections that differ by one
 * role. Role names stay provider-neutral — the provider name lives only on the
 * registered adapter (its `id`, `label`, `provider`), never in a role.
 *
 * Real adapters (for video, image, speech, music, lip-sync, transcribe)
 * register here the same way the fakes below do — the provider name lives on
 * the adapter's id/label/provider; nothing else in the pipeline changes when
 * they land. Model ids are code, not env (config is code).
 */

import { FakeStudio } from "./fakes";
import type {
  BreakdownRole,
  ImageRole,
  LipSyncRole,
  ModelSuite,
  MusicRole,
  RoleName,
  ScriptRole,
  StyleRole,
  TranscribeRole,
  VideoRole,
  VoiceRole,
} from "./capabilities";

export interface ModelOption {
  id: string;
  label: string;
  provider: string;
}

interface Registered<T> extends ModelOption {
  make: () => T;
}

class Slot<T> {
  private readonly options = new Map<string, Registered<T>>();
  private defaultId: string | undefined;

  register(entry: Registered<T>, isDefault = false): this {
    this.options.set(entry.id, entry);
    if (isDefault || this.defaultId === undefined) this.defaultId = entry.id;
    return this;
  }

  list(): ModelOption[] {
    return [...this.options.values()].map(({ id, label, provider }) => ({ id, label, provider }));
  }

  resolve(id?: string): T {
    const chosen = this.options.get(id ?? this.defaultId ?? "");
    if (!chosen) throw new Error(`no model registered${id ? ` with id "${id}"` : ""} for this role`);
    return chosen.make();
  }
}

export class ModelRegistry {
  readonly script = new Slot<ScriptRole>();
  readonly breakdown = new Slot<BreakdownRole>();
  readonly style = new Slot<StyleRole>();
  readonly image = new Slot<ImageRole>();
  readonly video = new Slot<VideoRole>();
  readonly voice = new Slot<VoiceRole>();
  readonly music = new Slot<MusicRole>();
  readonly lipSync = new Slot<LipSyncRole>();
  readonly transcribe = new Slot<TranscribeRole>();

  /** The models registered for one role — what a picker or an eval iterates. */
  options(role: RoleName): ModelOption[] {
    return (this[role] as Slot<unknown>).list();
  }

  /** Resolve a per-role selection into a runnable suite. */
  buildSuite(selection: Partial<Record<RoleName, string>>, label: string): ModelSuite {
    const video = this.video.resolve(selection.video);
    return {
      label,
      script: this.script.resolve(selection.script),
      breakdown: this.breakdown.resolve(selection.breakdown),
      style: this.style.resolve(selection.style),
      image: this.image.resolve(selection.image),
      video,
      voice: this.voice.resolve(selection.voice),
      music: this.music.resolve(selection.music),
      // A lip-sync model is only needed when the video model isn't audio-native.
      ...(video.audioNative ? {} : { lipSync: this.lipSync.resolve(selection.lipSync) }),
      transcribe: this.transcribe.resolve(selection.transcribe),
    };
  }
}

/**
 * A registry wired entirely to fakes, with two video variants so the swap
 * mechanism and the comparison eval are demonstrable end to end. Replace each
 * `make` with a real adapter to bring a model online.
 */
export function fakeRegistry(): ModelRegistry {
  const r = new ModelRegistry();
  const base = new FakeStudio({ label: "fake" }).suite();
  r.script.register({ id: "fake", label: "Fake script", provider: "fake", make: () => base.script });
  r.breakdown.register({ id: "fake", label: "Fake breakdown", provider: "fake", make: () => base.breakdown });
  r.style.register({ id: "fake", label: "Fake style", provider: "fake", make: () => base.style });
  r.image.register({ id: "fake", label: "Fake image", provider: "fake", make: () => base.image });
  r.voice.register({ id: "fake", label: "Fake voice", provider: "fake", make: () => base.voice });
  r.music.register({ id: "fake", label: "Fake music", provider: "fake", make: () => base.music });
  r.transcribe.register({ id: "fake", label: "Fake transcribe", provider: "fake", make: () => base.transcribe });
  r.lipSync.register({
    id: "fake",
    label: "Fake lip-sync",
    provider: "fake",
    make: () => new FakeStudio().suite().lipSync!,
  });
  // Two swappable video models to compare.
  r.video.register(
    { id: "fake-fast", label: "Fake video (fast)", provider: "fake", make: () => new FakeStudio({ videoVariant: "fast" }).suite().video },
    true
  );
  r.video.register({
    id: "fake-pro",
    label: "Fake video (pro, audio-native)",
    provider: "fake",
    make: () => new FakeStudio({ videoVariant: "pro", audioNative: true }).suite().video,
  });
  return r;
}
