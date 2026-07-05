import { Editor } from "@/cut/components/Editor";

export default async function ProjectPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  return <Editor projectId={id} />;
}
