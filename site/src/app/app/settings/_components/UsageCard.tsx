"use client";

import { useUsage } from "@/queries/billing";
import { Badge } from "@/components/ui/badge";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

export function UsageCard() {
  const usage = useUsage();

  if (usage.isLoading) {
    return (
      <Card>
        <CardHeader>
          <Skeleton className="h-6 w-32" />
        </CardHeader>
        <CardContent>
          <Skeleton className="h-24 w-full" />
        </CardContent>
      </Card>
    );
  }

  const data = usage.data;
  const limit = data?.limit ?? 0;
  const extra = data?.extraRemaining ?? 0;
  const pct =
    data && limit > 0
      ? Math.min(100, Math.round((data.used / limit) * 100))
      : 0;

  return (
    <Card>
      <CardHeader>
        <CardTitle>Usage this period</CardTitle>
        <CardDescription>
          {data && limit > 0
            ? `${data.used.toLocaleString()} of ${limit.toLocaleString()} calls used · ${data.remaining.toLocaleString()} remaining`
            : extra > 0
              ? "No subscription — using your extra calls."
              : "No active plan — subscribe to start making calls."}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {data && limit > 0 ? (
          <div
            aria-label="Quota used"
            className="h-2 w-full overflow-hidden rounded-full bg-muted"
          >
            <div
              className="h-full rounded-full bg-primary"
              style={{ width: `${pct}%` }}
            />
          </div>
        ) : null}

        {extra > 0 ? (
          <div className="flex items-baseline justify-between rounded-md border bg-muted/40 px-3 py-2">
            <span className="text-sm font-medium text-foreground">
              Extra calls
            </span>
            <span className="text-sm text-muted-foreground">
              {extra.toLocaleString()} available
            </span>
          </div>
        ) : null}

        <div>
          <h3 className="mb-2 text-sm font-medium">Recent calls</h3>
          {data && data.recent.length > 0 ? (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>When</TableHead>
                  <TableHead>Kind</TableHead>
                  <TableHead>Model</TableHead>
                  <TableHead>Status</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.recent.map((event, index) => (
                  <TableRow key={`${event.createdAt}-${index}`}>
                    <TableCell>
                      {new Date(event.createdAt).toLocaleString()}
                    </TableCell>
                    <TableCell>{event.requestKind}</TableCell>
                    <TableCell>{event.model}</TableCell>
                    <TableCell>
                      <Badge
                        variant={
                          event.status === "succeeded"
                            ? "secondary"
                            : "destructive"
                        }
                      >
                        {event.status}
                      </Badge>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          ) : (
            <p className="text-sm text-muted-foreground">No calls yet.</p>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
