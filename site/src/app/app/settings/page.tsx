import { redirect } from "next/navigation";

// Donkey Use no longer carries payment UI; settings opens on Usage.
export default function SettingsIndexPage() {
  redirect("/app/settings/usage");
}
