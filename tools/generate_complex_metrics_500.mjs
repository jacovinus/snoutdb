import {createWriteStream} from "node:fs";
import {once} from "node:events";
import {finished} from "node:stream/promises";

const DEFAULT_ROW_COUNT = 50_000;
const BATCH_SIZE = 10_000;
const rowCount = parseRowCount(process.argv[2] ?? String(DEFAULT_ROW_COUNT));
const outputDirectory = new URL("../tests/fixtures/", import.meta.url);
const outputStem = `complex_metrics_${rowCount}`;
const csvPath = new URL(`${outputStem}.csv`, outputDirectory);
const jsonlPath = new URL(`${outputStem}.jsonl`, outputDirectory);

const headers = [
  "call_id",
  "timestamp",
  "direction",
  "region",
  "carrier",
  "codec",
  "duration_seconds",
  "mos",
  "jitter_ms",
  "rtt_ms",
  "packet_loss_pct",
  "bitrate_kbps",
  "setup_time_ms",
  "concealed_packets",
  "result",
  "network_tag",
  "roaming",
  "customer_tier",
  "sip_code",
  "diagnostic",
];
const nullableFields = [
  "mos",
  "jitter_ms",
  "packet_loss_pct",
  "setup_time_ms",
  "network_tag",
  "roaming",
  "customer_tier",
  "diagnostic",
];
const regions = [
  "eu-west",
  "ap-south",
  "latam-south",
  "us-west",
  "us-east",
  "eu-central",
];
const carriers = [
  "Telco-A",
  "Telco-B",
  "Telco-C",
  "Transit-X",
  "FiberVoice",
];
const codecs = ["AMR-WB", "G722", "G711", "OPUS"];
const tiers = ["free", "standard", "business", "enterprise"];
const diagnostics = [
  "normal call",
  "minor jitter detected",
  "packet loss, recovered",
  'caller said "hello"',
  "handover completed",
  "high latency, investigate",
];
const baseTime = Date.parse("2026-06-08T10:00:00Z");

function parseRowCount(value) {
  if (!/^[1-9]\d*$/.test(value)) {
    throw new Error(`row count must be a positive integer, received: ${value}`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) {
    throw new Error(`row count is too large: ${value}`);
  }
  return parsed;
}

function makeRow(index) {
  const region = regions[(index * 5 + Math.floor(index / 17)) % regions.length];
  const carrier =
    carriers[(index * 3 + Math.floor(index / 13)) % carriers.length];
  const codec = codecs[(index + Math.floor(index / 19)) % codecs.length];
  const jitter = 2.5 + ((index * 41) % 7600) / 100;
  const packetLoss = ((index * 13) % 620) / 100;
  const roundTripTime = 25 + ((index * 17) % 310);
  const duration = 20 + ((index * 37) % 1781);
  const qualityPenalty =
    jitter * 0.018 +
    packetLoss * 0.16 +
    Math.max(0, roundTripTime - 150) * 0.0025;
  const mos = Math.max(1, Math.min(4.5, 4.48 - qualityPenalty));
  const result =
    mos < 2.4 || packetLoss > 5.3
      ? "failed"
      : mos < 3.45 || jitter > 55
        ? "degraded"
        : "completed";

  return {
    call_id: `CALL-${String(index).padStart(5, "0")}`,
    timestamp: new Date(baseTime + (index - 1) * 17_000)
      .toISOString()
      .replace(".000Z", "Z"),
    direction: index % 3 === 0 ? "inbound" : "outbound",
    region,
    carrier,
    codec,
    duration_seconds: duration,
    mos: index % 43 === 0 ? null : Number(mos.toFixed(2)),
    jitter_ms: index % 37 === 0 ? null : Number(jitter.toFixed(2)),
    rtt_ms: roundTripTime,
    packet_loss_pct:
      index % 53 === 0 ? null : Number(packetLoss.toFixed(2)),
    bitrate_kbps: codec === "AMR-WB" ? 23.85 : codec === "OPUS" ? 32 : 64,
    setup_time_ms: index % 61 === 0 ? null : 70 + ((index * 29) % 850),
    concealed_packets: Math.round(
      ((jitter + packetLoss * 20) * duration) / 18,
    ),
    result,
    network_tag:
      index % 11 === 0 ? null : index % 4 === 0 ? "backup" : "primary",
    roaming: index % 47 === 0 ? null : index % 7 === 0,
    customer_tier:
      index % 29 === 0 ? null : tiers[(index * 3) % tiers.length],
    sip_code: result === "failed" ? (index % 2 === 0 ? 503 : 408) : 200,
    diagnostic:
      index % 41 === 0 ? null : diagnostics[(index * 7) % diagnostics.length],
  };
}

function csvEscape(value) {
  if (value === null || value === undefined) {
    return "";
  }
  const text = String(value);
  if (/[",\n\r]/.test(text)) {
    return `"${text.replaceAll('"', '""')}"`;
  }
  return text;
}

function makeJsonRecord(row, rowIndex) {
  const record = {...row};
  for (const field of nullableFields) {
    if (record[field] === null && (rowIndex + field.length) % 2 === 0) {
      delete record[field];
    }
  }
  return record;
}

async function writeChunk(stream, chunk) {
  if (!stream.write(chunk)) {
    await once(stream, "drain");
  }
}

const csvStream = createWriteStream(csvPath, {encoding: "utf8"});
const jsonlStream = createWriteStream(jsonlPath, {encoding: "utf8"});

try {
  await writeChunk(csvStream, `${headers.join(",")}\n`);

  for (let batchStart = 1; batchStart <= rowCount; batchStart += BATCH_SIZE) {
    const batchEnd = Math.min(rowCount, batchStart + BATCH_SIZE - 1);
    const csvLines = [];
    const jsonlLines = [];

    for (let index = batchStart; index <= batchEnd; index += 1) {
      const row = makeRow(index);
      csvLines.push(headers.map((header) => csvEscape(row[header])).join(","));
      jsonlLines.push(JSON.stringify(makeJsonRecord(row, index - 1)));
    }

    await Promise.all([
      writeChunk(csvStream, `${csvLines.join("\n")}\n`),
      writeChunk(jsonlStream, `${jsonlLines.join("\n")}\n`),
    ]);

    if (batchEnd === rowCount || batchEnd % 100_000 === 0) {
      process.stderr.write(
        `generated ${batchEnd.toLocaleString("en-US")}/${rowCount.toLocaleString("en-US")} rows\r`,
      );
    }
  }

  csvStream.end();
  jsonlStream.end();
  await Promise.all([finished(csvStream), finished(jsonlStream)]);
  process.stderr.write("\n");
  console.log(`written: ${csvPath.pathname}`);
  console.log(`written: ${jsonlPath.pathname}`);
} catch (error) {
  csvStream.destroy();
  jsonlStream.destroy();
  throw error;
}
