/**
 * @name Discord Presence Bridge
 * @description Tells mpv which movie / show / episode is playing so the
 *              scripts/discord-presence script can show it on Discord
 *              ("Watching <title>"). Does nothing else.
 * @version 1.0.0
 *
 * @requires {window.RouteDetector}  - Kai: detects the player page + IMDb id
 * @requires {window.metadataHelper} - Kai: IndexedDB lookup (title, poster, year)
 * @requires {window.chrome.webview} - WebView2 -> shell -> mpv bridge
 *
 * Messages sent to the mpv script "discord_presence":
 *   presence-meta  <json>   a title started playing (re-sent when metadata arrives)
 *   presence-clear          the player page was left
 */

(function () {
  "use strict";

  // Idempotency guard (the shell can inject mods more than once)
  if (window.DiscordPresenceBridge?.initialized) return;
  window.DiscordPresenceBridge = { initialized: true };

  const MPV_SCRIPT = "discord_presence"; // = scripts/discord-presence/ (dash -> underscore)
  const META_RETRY_MS = 2000; // how often to re-check for metadata that was not ready
  const META_MAX_RETRIES = 10;

  let currentKey = null; // "<imdb>|<season>|<episode>" of what is playing
  let retryTimer = null;

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // ---- episode titles (Stremio's public Cinemeta service) ----
  const episodeTitles = new Map(); // route key -> episode title
  const episodeIndexes = new Map(); // imdb id -> Promise<Map<"season:episode", title> | null>

  function loadEpisodeIndex(imdb) {
    if (!episodeIndexes.has(imdb)) {
      const p = (async () => {
        const ctrl = new AbortController();
        const timer = setTimeout(() => ctrl.abort(), 8000);
        try {
          const res = await fetch(
            `https://v3-cinemeta.strem.io/meta/series/${imdb}.json`,
            { signal: ctrl.signal },
          );
          if (!res.ok) return null;
          const data = await res.json();
          const index = new Map();
          for (const v of data?.meta?.videos || []) {
            const name = v.name || v.title;
            const ep = v.episode ?? v.number;
            if (name && v.season != null && ep != null) {
              index.set(`${v.season}:${ep}`, String(name));
            }
          }
          return index;
        } catch (e) {
          return null;
        } finally {
          clearTimeout(timer);
        }
      })();
      episodeIndexes.set(imdb, p);
      p.then((index) => {
        if (!index) episodeIndexes.delete(imdb); // failed - allow a retry later
      });
    }
    return episodeIndexes.get(imdb);
  }

  function sendMeta(meta) {
    sendToMpv("script-message-to", [
      MPV_SCRIPT,
      "presence-meta",
      JSON.stringify(meta),
    ]);
  }

  /** Same transport Kai's mpv-bridge.js uses. */
  function sendToMpv(command, args) {
    const payload = {
      type: 6,
      object: "transport",
      method: "handleInboundJSON",
      args: ["mpv-command", [command, ...args]],
    };
    window.chrome?.webview?.postMessage(JSON.stringify(payload));
  }

  function routeKey(state) {
    return [state.id, state.season, state.episode].join("|");
  }

  /** Wait (briefly) for Kai's metadata helper, then read the stored entry. */
  async function lookupEntry(imdbId) {
    for (let i = 0; i < 25; i++) {
      if (window.metadataHelper?.getTitle) {
        try {
          return (await window.metadataHelper.getTitle(imdbId)) || null;
        } catch (e) {
          return null;
        }
      }
      await sleep(200);
    }
    return null;
  }

  async function pushMeta(state, key, attempt) {
    if (key !== currentKey) return; // user already moved on

    const entry = await lookupEntry(state.id);
    if (key !== currentKey) return;

    // Fields without a value are left out entirely (no JSON nulls for mpv to parse).
    const meta = {
      imdb: state.id,
      type: state.type || entry?.type || undefined, // "movie" | "series"
      season: state.season ?? undefined,
      episode: state.episode ?? undefined,
      title: entry?.title || undefined,
      year: entry?.year || undefined,
      poster: entry?.poster || undefined,
      episode_title: episodeTitles.get(key) || undefined,
    };
    sendMeta(meta);
    console.log(
      `[Discord Presence] meta -> ${meta.title ?? "(no title yet)"} ` +
        `[${meta.type} ${meta.imdb} S${meta.season} E${meta.episode}] (try ${attempt})`,
    );

    // Shows: look up the episode title once, then send the meta again with it.
    if (
      meta.type === "series" &&
      /^tt\d+$/.test(meta.imdb) &&
      meta.season != null &&
      meta.episode != null &&
      !meta.episode_title
    ) {
      loadEpisodeIndex(meta.imdb).then((index) => {
        const title = index?.get(`${meta.season}:${meta.episode}`);
        if (title && key === currentKey) {
          episodeTitles.set(key, title);
          sendMeta({ ...meta, episode_title: title });
          console.log(`[Discord Presence] episode title -> ${title}`);
        }
      });
    }

    // Metadata is filled in the background and may not exist yet - ask again.
    if (!meta.title && attempt < META_MAX_RETRIES) {
      clearTimeout(retryTimer);
      retryTimer = setTimeout(
        () => pushMeta(state, key, attempt + 1),
        META_RETRY_MS,
      );
    }
  }

  function onRouteChange() {
    if (!window.RouteDetector) return;

    window.RouteDetector.invalidateCache?.();
    const state = window.RouteDetector.getRouteState();

    if (state.view !== "PLAYER" || !state.id) {
      if (currentKey !== null) {
        currentKey = null;
        clearTimeout(retryTimer);
        sendToMpv("script-message-to", [MPV_SCRIPT, "presence-clear"]);
        console.log("[Discord Presence] left player -> clear");
      }
      return;
    }

    const key = routeKey(state);
    if (key === currentKey) return; // same episode, nothing new to say
    currentKey = key;
    clearTimeout(retryTimer);
    pushMeta(state, key, 0);
  }

  let initTries = 0;
  function init() {
    if (!window.RouteDetector) {
      if (initTries++ > 100) {
        console.warn("[Discord Presence] RouteDetector never appeared - giving up");
        return;
      }
      setTimeout(init, 100);
      return;
    }
    window.addEventListener("hashchange", onRouteChange);
    onRouteChange(); // in case we are already on the player page
    console.log(
      "%c[Discord Presence] Initialized",
      "color: #5865f2; font-weight: bold",
    );
  }

  init();
})();
