"use client";

import { useState } from "react";

import {
  useApiKeys,
  useCreateApiKey,
  useDeleteApiKey,
  type CreatedApiKey,
} from "@/queries/apiKeys";
import { useSubscription, useUsage } from "@/queries/billing";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

export function ApiKeysManager() {
  const subscription = useSubscription();
  const usage = useUsage();
  const keys = useApiKeys();
  const createKey = useCreateApiKey();
  const deleteKey = useDeleteApiKey();

  const [name, setName] = useState("");
  const [createdKey, setCreatedKey] = useState<CreatedApiKey | null>(null);

  // Keys can always be created, but only return data when the user has capacity:
  // an active subscription or remaining extra calls.
  const hasCapacity =
    (subscription.data?.isActive ?? false) ||
    (usage.data?.extraRemaining ?? 0) > 0;

  const handleCreate = () => {
    const trimmed = name.trim();
    if (!trimmed) {
      return;
    }
    createKey.mutate(trimmed, {
      onSuccess: (result) => {
        setCreatedKey(result);
        setName("");
      },
    });
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>Your keys</CardTitle>
        <CardDescription>
          Secrets are shown only once at creation. Store them securely.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-6">
        <div className="space-y-3">
          <div className="flex items-end gap-3">
            <div className="grid gap-1.5">
              <Label htmlFor="key-name">New key name</Label>
              <Input
                id="key-name"
                placeholder="Production server"
                value={name}
                onChange={(event) => setName(event.target.value)}
              />
            </div>
            <Button
              disabled={createKey.isPending || !name.trim()}
              onClick={handleCreate}
            >
              {createKey.isPending ? "Creating…" : "Create key"}
            </Button>
          </div>
          {!hasCapacity ? (
            <p className="text-sm text-muted-foreground">
              Keys won&apos;t return data until you have available calls —
              subscribe or use your free calls.
            </p>
          ) : null}
        </div>

        {keys.isLoading ? (
          <Skeleton className="h-24 w-full" />
        ) : keys.data && keys.data.length > 0 ? (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Name</TableHead>
                <TableHead>Key</TableHead>
                <TableHead>Created</TableHead>
                <TableHead>Last used</TableHead>
                <TableHead className="text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {keys.data.map((key) => (
                <TableRow key={key.id}>
                  <TableCell>{key.name ?? "—"}</TableCell>
                  <TableCell className="font-mono text-xs">
                    {(key.prefix ?? "") + (key.start ?? "")}…
                  </TableCell>
                  <TableCell>
                    {new Date(key.createdAt).toLocaleDateString()}
                  </TableCell>
                  <TableCell>
                    {key.lastRequest
                      ? new Date(key.lastRequest).toLocaleDateString()
                      : "Never"}
                  </TableCell>
                  <TableCell className="text-right">
                    <Button
                      disabled={deleteKey.isPending}
                      onClick={() => deleteKey.mutate(key.id)}
                      size="sm"
                      variant="destructive"
                    >
                      Revoke
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        ) : (
          <p className="text-sm text-muted-foreground">No API keys yet.</p>
        )}
      </CardContent>

      <Dialog
        open={createdKey !== null}
        onOpenChange={(open) => {
          if (!open) {
            setCreatedKey(null);
          }
        }}
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>API key created</DialogTitle>
            <DialogDescription>
              Copy this secret now. You won&apos;t be able to see it again.
            </DialogDescription>
          </DialogHeader>
          <div className="rounded-md border bg-muted p-3 font-mono text-sm break-all">
            {createdKey?.secret}
          </div>
          <DialogFooter>
            <Button
              onClick={() => {
                if (createdKey) {
                  void navigator.clipboard.writeText(createdKey.secret);
                }
              }}
              variant="secondary"
            >
              Copy
            </Button>
            <Button onClick={() => setCreatedKey(null)}>Done</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </Card>
  );
}
