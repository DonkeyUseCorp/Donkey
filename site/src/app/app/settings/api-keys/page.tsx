import { headers } from "next/headers";
import { redirect } from "next/navigation";

import { ApiKeysManager } from "@/app/app/settings/_components/ApiKeysManager";
import { isDonkeycutHost } from "@/cut/lib/hosts";

// Vision API keys are a Donkey product surface; on donkeycut.com the settings
// pages carry only the Cut-relevant tabs (see SettingsShell), and a deep link
// here lands on the overview instead.
export default async function ApiKeysPage() {
  if (isDonkeycutHost((await headers()).get("host"))) redirect("/app/settings");
  return <ApiKeysManager />;
}
