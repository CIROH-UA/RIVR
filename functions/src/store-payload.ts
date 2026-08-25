// functions/src/store-payload.ts
//
// ADR 0011 Phase 4 Build: "Store the trimmed payload — the app reads
// `mediumRange['mean']`, and storing only that should cut 156 KB substantially
// and keeps documents far from Firestore's 1 MiB limit."
//
// The client decodes a stored payload with `ForecastResponseDto.fromApiResponse`
// (see narrow_nwm_payloads.dart / nwm_data_source.dart), i.e. the payload IS a
// NOAA response body. Trimming therefore cannot reshape it — it can only drop
// keys the decoder never reads. Anything else and the document decodes to null
// inside the app with no server-side symptom.
//
// Two limits this defends:
//   - Firestore's 1 MiB per document, a hard write failure.
//   - The measured 156 KB medium-range response, of which the app reads one
//     member.
//
// Trimming is conservative on purpose: an unrecognised product is passed
// through untouched rather than emptied. Dropping data because this file has
// not been taught about a product yet would be the silent-partial-data failure
// the project keeps hitting.

import {ForecastProductId, SECTION_BY_PRODUCT} from "./store-keys.js";

/** Firestore's hard per-document ceiling. */
export const FIRESTORE_DOC_LIMIT_BYTES = 1024 * 1024;

/**
 * Refuse to write above this. Well under the hard limit, because the encoded
 * size Firestore counts is larger than JSON.stringify's byte length (field
 * names, type tags, index entries).
 */
export const PAYLOAD_WARN_BYTES = 700 * 1024;

/**
 * Ensemble sections the app reads a single member from. `nwm_data_source`
 * takes `mean`; keeping 20+ members would store two orders of magnitude more
 * than anything reads.
 */
const MEAN_ONLY_SECTIONS = new Set(["mediumRange", "longRange"]);

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/**
 * Drop everything the client will not read for [product].
 *
 * @param {ForecastProductId} product - Which product this payload is for.
 * @param {Record<string, unknown>} raw - The upstream response body.
 * @return {Record<string, unknown>} The payload to store.
 */
export function trimPayload(
  product: ForecastProductId,
  raw: Record<string, unknown>
): Record<string, unknown> {
  if (product === "returnPeriods") {
    // Already narrow; the client reads payload['returnPeriods'] verbatim.
    return "returnPeriods" in raw ? {returnPeriods: raw.returnPeriods} : raw;
  }

  if (product === "reachMetadata") {
    // reach_metadata_payload.dart reads exactly these four.
    const keep = ["riverName", "formattedLocation", "latitude", "longitude"];
    const out: Record<string, unknown> = {};
    let found = false;
    for (const k of keep) {
      if (k in raw) {
        out[k] = raw[k];
        found = true;
      }
    }
    return found ? out : raw;
  }

  const section = SECTION_BY_PRODUCT[product];
  // GEOGLOWS products and anything unrecognised pass through untouched.
  //
  // `section in raw` is not enough: NOAA returns ALL five section keys in
  // every response, with the unrequested ones as `{}`. Keeping an empty
  // section writes a document with a correct runId and no flow data at all.
  if (!section) return raw;
  const sectionBody = raw[section];
  if (sectionBody === undefined || sectionBody === null) return raw;
  if (isObject(sectionBody) && Object.keys(sectionBody).length === 0) {
    return raw;
  }

  const out: Record<string, unknown> = {};
  // `reach` carries the identity the DTO needs to parse the body; dropping it
  // makes fromApiResponse throw, which the client reports as "no value".
  if ("reach" in raw) out.reach = raw.reach;

  const body = raw[section];
  if (MEAN_ONLY_SECTIONS.has(section) && isObject(body) && "mean" in body) {
    out[section] = {mean: body.mean};
  } else {
    out[section] = body;
  }
  return out;
}

/** Approximate stored size. @param {unknown} payload - Payload. @return {number} Bytes. */
export function payloadBytes(payload: unknown): number {
  return Buffer.byteLength(JSON.stringify(payload ?? null), "utf8");
}

/** Thrown when a payload is too large to store safely. */
export class PayloadTooLargeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PayloadTooLargeError";
  }
}

/**
 * Refuse an oversized payload before the write is attempted.
 *
 * Firestore rejects >1 MiB with an error, but a document just under it is
 * worse: it writes, costs, and drags every client read. Failing here leaves
 * the previous document intact and routes the reach to retry (guard 4), which
 * is the honest outcome.
 *
 * @param {string} documentId - For the message.
 * @param {unknown} payload - The trimmed payload.
 * @throws {PayloadTooLargeError} When above [PAYLOAD_WARN_BYTES].
 */
export function assertPayloadFits(documentId: string, payload: unknown): void {
  const bytes = payloadBytes(payload);
  if (bytes > PAYLOAD_WARN_BYTES) {
    throw new PayloadTooLargeError(
      `${documentId}: trimmed payload is ${bytes} bytes, over the ` +
      `${PAYLOAD_WARN_BYTES}-byte ceiling (Firestore hard limit ` +
      `${FIRESTORE_DOC_LIMIT_BYTES}) — refusing to write`
    );
  }
}
