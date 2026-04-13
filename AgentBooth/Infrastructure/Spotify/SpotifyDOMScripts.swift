import Foundation

private let sharedSpotifyDOMHelperJS = """
function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function textOf(element) {
  return (element?.textContent || "").replace(/\\s+/g, " ").trim();
}

function normalizeURL(value) {
  try {
    return new URL(value, window.location.origin).toString();
  } catch (_) {
    return "";
  }
}

function normalizePath(value) {
  try {
    const url = new URL(value, window.location.origin);
    return url.pathname;
  } catch (_) {
    return value || "";
  }
}

function matchHref(actual, expected) {
  if (!actual || !expected) return false;
  const actualURL = normalizeURL(actual);
  const expectedURL = normalizeURL(expected);
  if (actualURL === expectedURL) return true;
  return normalizePath(actualURL) === normalizePath(expectedURL);
}

function firstElement(selectors, root = document) {
  for (const selector of selectors) {
    const element = root.querySelector(selector);
    if (element) return element;
  }
  return null;
}

function firstText(selectors, root = document) {
  const element = firstElement(selectors, root);
  return textOf(element);
}

function uniqueBy(items, keyBuilder) {
  const seen = new Set();
  const output = [];
  for (const item of items) {
    let key = "";
    try {
      key = keyBuilder(item);
    } catch (_) {
      key = "";
    }
    if (!key || seen.has(key)) continue;
    seen.add(key);
    output.push(item);
  }
  return output;
}

function attributeOf(element, name) {
  if (!element || typeof element.getAttribute !== "function") return "";
  return element.getAttribute(name) || "";
}

function clickElement(element) {
  if (!element) return false;
  element.scrollIntoView({ block: "center", inline: "nearest" });
  element.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
  element.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  element.dispatchEvent(new MouseEvent("mouseup", { bubbles: true, cancelable: true }));
  element.click();
  return true;
}

function parseDuration(text) {
  const value = (text || "").trim();
  if (!value) return 0;
  const parts = value.split(":").map(Number).filter(n => !Number.isNaN(n));
  if (parts.length === 2) return (parts[0] * 60) + parts[1];
  if (parts.length === 3) return (parts[0] * 3600) + (parts[1] * 60) + parts[2];
  return 0;
}

function detectScrollableContainers() {
  const candidates = [
    document.querySelector('[data-testid="left-sidebar"] [data-overlayscrollbars-viewport]'),
    document.querySelector('[data-testid="left-sidebar"]'),
    document.querySelector('[aria-label*="Your Library"] [data-overlayscrollbars-viewport]'),
    document.querySelector("aside"),
    document.querySelector("main"),
    document.scrollingElement,
  ].filter(Boolean);
  return uniqueBy(candidates, item => {
    const tagName = item?.tagName || "unknown";
    return tagName + ":" + attributeOf(item, "data-testid") + ":" + attributeOf(item, "aria-label");
  }).filter(item => typeof item.scrollTop === "number");
}

function buildPlaylistURLFromTitleNodeID(rawID) {
  const prefix = "listrow-title-spotify:playlist:";
  if (!rawID || !rawID.startsWith(prefix)) return "";
  const playlistID = rawID.slice(prefix.length).trim();
  if (!playlistID) return "";
  return "https://open.spotify.com/playlist/" + playlistID;
}

function collectPlaylistTitleNodes() {
  const items = [];
  const nodes = Array.from(
    document.querySelectorAll('p[data-encore-id="listRowTitle"][id^="listrow-title-spotify:playlist:"]')
  );
  for (const node of nodes) {
    const href = buildPlaylistURLFromTitleNodeID(attributeOf(node, "id"));
    const title = textOf(node);
    if (!href || !title) continue;
    items.push({ title, href });
  }
  return uniqueBy(items, item => item.href);
}

function collectPlaylistAnchors() {
  const items = [];
  for (const item of collectPlaylistTitleNodes()) {
    items.push(item);
  }
  const anchors = Array.from(document.querySelectorAll('a[href*="/playlist/"]'));
  for (const anchor of anchors) {
    const href = normalizeURL(attributeOf(anchor, "href"));
    const title = textOf(anchor)
      || attributeOf(anchor, "aria-label")
      || attributeOf(anchor, "title");
    const normalizedTitle = title.replace(/^Pinned\\s+/i, "").trim();
    if (!href || !normalizedTitle) continue;
    if (!href.includes("/playlist/")) continue;
    items.push({ title: normalizedTitle, href });
  }
  return uniqueBy(items, item => item.href);
}

function scrollContainerToBottom(container) {
  if (!container || typeof container.scrollTop !== "number") return;
  if (typeof container.scrollTo === "function") {
    container.scrollTo({ top: container.scrollHeight, behavior: "instant" });
    return;
  }
  container.scrollTop = container.scrollHeight;
}

function normalizeTextValue(value) {
  return (value || "").replace(/\\s+/g, " ").trim();
}

function findPlaylistTracklistRoot(playlistName) {
  const normalizedPlaylistName = normalizeTextValue(playlistName);
  const roots = Array.from(document.querySelectorAll('div[role="grid"][data-testid="playlist-tracklist"]'));
  for (const root of roots) {
    const ariaLabel = normalizeTextValue(attributeOf(root, "aria-label"));
    if (ariaLabel && ariaLabel === normalizedPlaylistName) {
      return root;
    }
  }
  for (const root of roots) {
    const ariaLabel = normalizeTextValue(attributeOf(root, "aria-label"));
    if (ariaLabel && normalizedPlaylistName && ariaLabel.includes(normalizedPlaylistName)) {
      return root;
    }
  }
  return null;
}

function detectTrackRows(playlistName) {
  const root = findPlaylistTracklistRoot(playlistName);
  if (!root) return [];
  const selectors = [
    'div[data-testid="tracklist-row"]',
    '[role="row"][aria-rowindex]',
    'div[role="row"]',
  ];
  for (const selector of selectors) {
    const rows = Array.from(root.querySelectorAll(selector));
    if (rows.length > 0) return rows;
  }
  return [];
}

function parseTrackRow(row) {
  const trackAnchor = firstElement(
    [
      'a[href*="/track/"]',
      '[data-testid="internal-track-link"]',
    ],
    row
  );
  const episodeAnchor = firstElement(['a[href*="/episode/"]', 'a[href*="/show/"]'], row);
  const trackTitle = textOf(trackAnchor) || firstText(['img[alt]'], row);
  const artistLinks = Array.from(row.querySelectorAll('a[href*="/artist/"]'))
    .map(element => textOf(element))
    .filter(Boolean);
  const album = firstText(['a[href*="/album/"]'], row);
  const durationCandidates = Array.from(row.querySelectorAll("span, div"))
    .map(element => textOf(element))
    .filter(value => /^(?:\\d+:)?\\d{1,2}:\\d{2}$/.test(value));
  const rowText = textOf(row).toLowerCase();
  let contentType = "track";
  if (episodeAnchor || rowText.includes("episode")) {
    contentType = "episode";
  } else if (rowText.includes("local files") || rowText.includes("ローカルファイル")) {
    contentType = "local";
  }

  return {
    title: trackTitle,
    artist: artistLinks[0] || "",
    album,
    durationSeconds: durationCandidates.length > 0
      ? parseDuration(durationCandidates[durationCandidates.length - 1])
      : 0,
    href: normalizeURL(trackAnchor?.getAttribute("href") || ""),
    playlistURL: normalizeURL(window.location.href),
    isPlayable: Boolean(trackAnchor && trackTitle),
    contentType,
  };
}

function findPlayPauseButton() {
  return firstElement([
    'button[data-testid="control-button-playpause"]',
    'footer button[aria-label*="Pause"]',
    'footer button[aria-label*="Play"]',
    'footer button[aria-label*="一時停止"]',
    'footer button[aria-label*="再生"]',
  ]);
}

function inferIsPlaying() {
  const button = findPlayPauseButton();
  const label = (button?.getAttribute("aria-label") || button?.getAttribute("title") || "").toLowerCase();
  if (label.includes("pause") || label.includes("一時停止")) return true;
  if (label.includes("play") || label.includes("再生")) return false;
  return Boolean(document.querySelector('button[data-testid="control-button-playpause"] svg[aria-label*="Pause"]'));
}

function parseNumericAttribute(element, name, fallbackValue = 0) {
  const rawValue = element?.getAttribute?.(name);
  const parsedValue = Number(rawValue);
  return Number.isFinite(parsedValue) ? parsedValue : fallbackValue;
}

function normalizeSliderValue(value, minValue, maxValue) {
  if (!Number.isFinite(value) || !Number.isFinite(minValue) || !Number.isFinite(maxValue)) return null;
  const span = maxValue - minValue;
  if (span <= 0) return null;
  return Math.max(0, Math.min(100, ((value - minValue) / span) * 100));
}

function denormalizeSliderValue(level, minValue, maxValue) {
  if (!Number.isFinite(level) || !Number.isFinite(minValue) || !Number.isFinite(maxValue)) return null;
  const clampedLevel = Math.max(0, Math.min(100, level));
  return minValue + ((maxValue - minValue) * (clampedLevel / 100));
}

function containsVolumeKeyword(value) {
  const normalized = (value || "").toLowerCase();
  return normalized.includes("volume")
    || normalized.includes("mute")
    || normalized.includes("音量")
    || normalized.includes("ミュート")
    || normalized.includes("消音");
}

function elementHasVolumeContext(element) {
  if (!element) return false;
  if (containsVolumeKeyword(attributeOf(element, "aria-label"))) return true;
  const labelledNodes = Array.from(element.querySelectorAll?.('[aria-label]') || []);
  return labelledNodes.some(node => containsVolumeKeyword(attributeOf(node, "aria-label")));
}

function findVolumeProgressBar() {
  const candidates = Array.from(document.querySelectorAll('footer [data-testid="progress-bar"]'));
  for (const candidate of candidates) {
    const contexts = [
      candidate,
      candidate.parentElement,
      candidate.parentElement?.parentElement,
      candidate.parentElement?.parentElement?.parentElement,
    ].filter(Boolean);
    if (contexts.some(elementHasVolumeContext)) {
      return candidate;
    }
  }
  return candidates.length > 0 ? candidates[candidates.length - 1] : null;
}

function findVolumeBarRoot() {
  return firstElement([
    '[data-testid="volume-bar"]',
    'footer [data-testid="volume-bar"]',
    'footer [role="slider"][aria-valuemin]',
    'footer input[type="range"]',
    'footer button[aria-label*="音量"]',
    'footer button[aria-label*="Volume"]',
  ]) || findVolumeProgressBar();
}

function findVolumeControl() {
  const volumeBarRoot = findVolumeBarRoot();
  if (!volumeBarRoot) return null;
  if (volumeBarRoot instanceof HTMLInputElement) return volumeBarRoot;
  if (attributeOf(volumeBarRoot, "role") === "slider") return volumeBarRoot;
  if (attributeOf(volumeBarRoot, "data-testid") === "progress-bar") return volumeBarRoot;
  return firstElement([
    'input[type="range"]',
    '[role="slider"][aria-valuemin]',
    '[role="slider"]',
  ], volumeBarRoot);
}

function readProgressBarLevel(control) {
  const styleText = attributeOf(control, "style");
  const hoverMatch = styleText.match(/--hover-bar-transform:\\s*([0-9.]+)%/);
  if (hoverMatch) return Math.max(0, Math.min(100, Number(hoverMatch[1])));
  const progressMatch = styleText.match(/--progress-bar-transform:\\s*([0-9.]+)%/);
  if (progressMatch) return Math.max(0, Math.min(100, Number(progressMatch[1])));
  const anchorNode = control.querySelector('[style*="left:"]');
  const anchorStyle = attributeOf(anchorNode, "style");
  const leftMatch = anchorStyle.match(/left:\\s*([0-9.]+)%/);
  if (leftMatch) return Math.max(0, Math.min(100, Number(leftMatch[1])));
  return null;
}

function readVolumeLevel() {
  const control = findVolumeControl();
  if (!control) return null;
  if (control instanceof HTMLInputElement) {
    const minValue = Number.isFinite(Number(control.min)) ? Number(control.min) : 0;
    const maxValue = Number.isFinite(Number(control.max)) ? Number(control.max) : 100;
    return normalizeSliderValue(Number(control.value), minValue, maxValue);
  }
  if (attributeOf(control, "data-testid") === "progress-bar") {
    return readProgressBarLevel(control);
  }
  const minValue = parseNumericAttribute(control, "aria-valuemin", 0);
  const maxValue = parseNumericAttribute(control, "aria-valuemax", 100);
  const currentValue = parseNumericAttribute(control, "aria-valuenow", Number.NaN);
  if (!Number.isFinite(currentValue)) return null;
  return normalizeSliderValue(currentValue, minValue, maxValue);
}

function dispatchPointerSequence(element, clientX, clientY) {
  const common = {
    bubbles: true,
    cancelable: true,
    clientX,
    clientY,
  };
  element.dispatchEvent(new MouseEvent("mouseenter", common));
  element.dispatchEvent(new MouseEvent("mouseover", common));
  element.dispatchEvent(new MouseEvent("mousemove", common));
  element.dispatchEvent(new PointerEvent("pointerdown", { ...common, pointerId: 1, pointerType: "mouse", isPrimary: true, buttons: 1 }));
  element.dispatchEvent(new MouseEvent("mousedown", { ...common, buttons: 1 }));
  element.dispatchEvent(new PointerEvent("pointerup", { ...common, pointerId: 1, pointerType: "mouse", isPrimary: true }));
  element.dispatchEvent(new MouseEvent("mouseup", common));
  element.dispatchEvent(new MouseEvent("click", common));
}

function describeVolumeControl(control) {
  if (!control) return { kind: "missing" };
  return {
    kind: control instanceof HTMLInputElement ? "input" : (attributeOf(control, "role") || control.tagName || "unknown"),
    min: control instanceof HTMLInputElement ? control.min : attributeOf(control, "aria-valuemin"),
    max: control instanceof HTMLInputElement ? control.max : attributeOf(control, "aria-valuemax"),
    value: control instanceof HTMLInputElement ? control.value : attributeOf(control, "aria-valuenow"),
    ariaLabel: attributeOf(control, "aria-label"),
    testID: attributeOf(control, "data-testid"),
    style: attributeOf(control, "style"),
  };
}

function findSeekBarRoot() {
  // progress-bar-handle を内包する progress-bar を優先（音量バーと区別）
  const allBars = Array.from(document.querySelectorAll('[data-testid="progress-bar"]'));
  for (const bar of allBars) {
    if (bar.querySelector('[data-testid="progress-bar-handle"]')) return bar;
  }
  return firstElement([
    '[data-testid="playback-progressbar"]',
    'footer [data-testid="progress-bar"]:first-child',
    'footer [data-testid="progress-bar"]',
  ]);
}

// [data-testid="playback-position"] のテキストから再生位置（秒）を返す。
function readSeekPositionMs() {
  const el = document.querySelector('[data-testid="playback-position"]');
  if (!el) return null;
  const text = textOf(el);
  return /^\\d+:\\d{2}(:\\d{2})?$/.test(text) ? parseDuration(text) : null;
}

// [data-testid="playback-duration"] のテキストから総再生時間（秒）を返す。
function readSeekDurationMs() {
  const el = document.querySelector('[data-testid="playback-duration"]');
  if (!el) return null;
  const text = textOf(el);
  return /^\\d+:\\d{2}(:\\d{2})?$/.test(text) ? parseDuration(text) : null;
}

// ms または秒と思われる値を秒単位に正規化する。
// Spotify は通常ミリ秒を使用するため、10000 以上なら ms として扱う。
function msOrSecondsToSeconds(value) {
  return value > 10000 ? value / 1000 : value;
}

function readPlayerTrack() {
  const footer = document.querySelector("footer") || document;
  const trackAnchor = firstElement([
    'footer a[href*="/track/"]',
    '[data-testid="context-item-link"]',
  ], footer);
  if (!trackAnchor) return null;
  const artistLinks = Array.from(footer.querySelectorAll('a[href*="/artist/"]'))
    .map(element => textOf(element))
    .filter(Boolean);
  return {
    href: normalizeURL(trackAnchor.getAttribute("href") || ""),
    title: textOf(trackAnchor),
    artist: artistLinks[0] || "",
  };
}
"""

/// Spotify Web DOM 操作用の JavaScript 定義群。
enum SpotifyDOMScripts {
    /// ログイン状態を DOM から推測する。
    static let detectLoginState = """
    return (async () => {
      try {
        \(sharedSpotifyDOMHelperJS)
        const path = window.location.pathname || "";
        const hasLoginButton = Boolean(document.querySelector('[data-testid="login-button"], a[href*="/login"], button[data-testid="login-button"]'));
        const hasUserWidget = Boolean(document.querySelector('[data-testid="user-widget-link"], button[aria-haspopup="menu"]'));
        const hasSpotifyChrome = Boolean(document.querySelector('footer') || document.querySelector('main') || document.querySelector('aside'));
        const isLoggedIn = hasUserWidget || (!hasLoginButton && hasSpotifyChrome && !path.startsWith("/login") && !path.startsWith("/signup"));
        return JSON.stringify({
          isLoggedIn,
          currentURL: normalizeURL(window.location.href),
        });
      } catch (error) {
        return JSON.stringify({ "__error": error.message || String(error) });
      }
    })();
    """

    /// サイドバーから現在見えているプレイリスト一覧を抽出する。
    static let fetchSidebarPlaylists = """
    (() => {
      const selector = 'p[data-encore-id="listRowTitle"][id^="listrow-title-spotify:playlist:"]';
      const prefix = "listrow-title-spotify:playlist:";
      const normalizeText = value => (value || "").replace(/\\s+/g, " ").trim();
      const buildURL = rawID => {
        if (!rawID || !rawID.startsWith(prefix)) return "";
        const playlistID = rawID.slice(prefix.length).trim();
        if (!playlistID) return "";
        return "https://open.spotify.com/playlist/" + playlistID;
      };
      try {
        const nodes = Array.from(document.querySelectorAll(selector));
        const items = [];
        const seen = new Set();
        for (const node of nodes) {
          const title = normalizeText(node.textContent);
          const href = buildURL(node.getAttribute("id") || "");
          if (!title || !href || seen.has(href)) continue;
          seen.add(href);
          items.push({ title, href });
        }
        return JSON.stringify(items);
      } catch (error) {
        return JSON.stringify({
          "__error": error.message || String(error),
          "url": window.location.href || "",
        });
      }
    })()
    """

    /// プレイリスト一覧取得のためサイドバーを下方向へ送る。
    static let scrollSidebarPlaylists = """
    (() => {
      try {
        const container =
          document.querySelector('[data-testid="left-sidebar"] [data-overlayscrollbars-viewport]') ||
          document.querySelector('[data-testid="left-sidebar"]') ||
          document.querySelector("aside") ||
          document.scrollingElement;
        if (!container || typeof container.scrollTop !== "number") {
          return JSON.stringify({ ok: false, moved: false });
        }
        const previousTop = container.scrollTop;
        container.scrollTop = container.scrollHeight;
        return JSON.stringify({
          ok: true,
          moved: container.scrollTop !== previousTop,
          scrollTop: container.scrollTop,
        });
      } catch (error) {
        return JSON.stringify({
          "__error": error.message || String(error),
          "url": window.location.href || "",
        });
      }
    })()
    """

    /// プレイリストのトラック行が読める状態かを返す。
    static func checkTrackRowsReady(playlistName: String) -> String {
        """
        return (async () => {
          try {
            \(sharedSpotifyDOMHelperJS)
            const playlistName = \(quotedJSONString(playlistName));
            return JSON.stringify({
              rowCount: detectTrackRows(playlistName).length,
              currentURL: normalizeURL(window.location.href),
            });
          } catch (error) {
            return JSON.stringify({ "__error": error.message || String(error) });
          }
        })();
        """
    }

    /// 現在表示中プレイリストのトラック一覧を抽出する。
    static func fetchPlaylistTracks(playlistName: String) -> String {
        """
        return (async () => {
          try {
            \(sharedSpotifyDOMHelperJS)
            const playlistName = \(quotedJSONString(playlistName));
            const tracklistRoot = findPlaylistTracklistRoot(playlistName);
            if (!tracklistRoot) {
              return JSON.stringify({
                "__error": "プレイリスト tracklist root が見つかりませんでした。",
                "playlistName": playlistName,
                "currentURL": normalizeURL(window.location.href),
              });
            }
            let previousCount = -1;
            let stableCount = 0;
            for (let index = 0; index < 18; index += 1) {
              const rows = detectTrackRows(playlistName);
              if (rows.length === previousCount) {
                stableCount += 1;
              } else {
                stableCount = 0;
              }
              if (stableCount >= 2) break;
              previousCount = rows.length;
              if (tracklistRoot instanceof HTMLElement) {
                tracklistRoot.scrollTop = tracklistRoot.scrollHeight;
              }
              await sleep(180);
            }
            const items = detectTrackRows(playlistName)
              .map(row => parseTrackRow(row))
              .filter(item => item.title || item.href || item.contentType !== "track");
            return JSON.stringify(items);
          } catch (error) {
            return JSON.stringify({ "__error": error.message || String(error) });
          }
        })();
        """
    }

    /// トラック行を再特定してクリック再生する。
    static func playTrack(trackHref: String, trackName: String, artistName: String, playlistName: String) -> String {
        """
        return (async () => {
          try {
            \(sharedSpotifyDOMHelperJS)
            const desiredHref = \(quotedJSONString(trackHref));
            const desiredTitle = \(quotedJSONString(trackName));
            const desiredArtist = \(quotedJSONString(artistName));
            const playlistName = \(quotedJSONString(playlistName));
            const rows = detectTrackRows(playlistName);
            let targetRow = null;
            for (const row of rows) {
              const item = parseTrackRow(row);
              if (item.contentType !== "track") continue;
              const matchedHref = desiredHref ? matchHref(item.href, desiredHref) : false;
              const matchedText = item.title === desiredTitle && (!desiredArtist || item.artist === desiredArtist);
              if (matchedHref || matchedText) {
                targetRow = row;
                break;
              }
            }
            if (!targetRow) {
              return JSON.stringify({
                "__error": "対象トラック行を再特定できませんでした。",
                "candidateCount": rows.length,
                "currentURL": normalizeURL(window.location.href),
              });
            }
            targetRow.scrollIntoView({ block: "center", inline: "nearest" });
            await sleep(150);
            const playButton = firstElement([
              'button[data-testid="play-button"]',
              'button[aria-label*="Play"]',
              'button[aria-label*="再生"]',
            ], targetRow);
            if (clickElement(playButton)) {
              await sleep(200);
              return JSON.stringify({ ok: true, method: "button" });
            }
            const trackAnchor = firstElement(['a[href*="/track/"]'], targetRow);
            if (trackAnchor) {
              trackAnchor.dispatchEvent(new MouseEvent("dblclick", { bubbles: true, cancelable: true }));
              trackAnchor.click();
              await sleep(200);
              return JSON.stringify({ ok: true, method: "anchor" });
            }
            return JSON.stringify({
              "__error": "再生ボタンが見つかりませんでした。",
              "outerHTML": targetRow.outerHTML.slice(0, 800),
            });
          } catch (error) {
            return JSON.stringify({ "__error": error.message || String(error) });
          }
        })();
        """
    }

    /// 一時停止する。
    static let pausePlayback = """
    return (async () => {
      try {
        \(sharedSpotifyDOMHelperJS)
        const button = findPlayPauseButton();
        if (!button) {
          return JSON.stringify({ "__error": "再生ボタンが見つかりませんでした。" });
        }
        if (!inferIsPlaying()) {
          return JSON.stringify({ ok: true, changed: false });
        }
        clickElement(button);
        await sleep(120);
        return JSON.stringify({ ok: true, changed: true });
      } catch (error) {
        return JSON.stringify({ "__error": error.message || String(error) });
      }
    })();
    """

    /// 再生を再開する。
    static let resumePlayback = """
    return (async () => {
      try {
        \(sharedSpotifyDOMHelperJS)
        const button = findPlayPauseButton();
        if (!button) {
          return JSON.stringify({ "__error": "再生ボタンが見つかりませんでした。" });
        }
        if (inferIsPlaying()) {
          return JSON.stringify({ ok: true, changed: false });
        }
        clickElement(button);
        await sleep(120);
        return JSON.stringify({ ok: true, changed: true });
      } catch (error) {
        return JSON.stringify({ "__error": error.message || String(error) });
      }
    })();
    """

    /// 音量を設定する。
    static func setVolume(_ level: Int) -> String {
        """
        return (async () => {
          try {
            \(sharedSpotifyDOMHelperJS)
            const desiredLevel = Math.max(0, Math.min(100, \(level)));
            const control = findVolumeControl();
            if (!control) {
              return JSON.stringify({ "__error": "音量スライダーが見つかりませんでした。" });
            }
            if (control instanceof HTMLInputElement) {
              const minValue = Number.isFinite(Number(control.min)) ? Number(control.min) : 0;
              const maxValue = Number.isFinite(Number(control.max)) ? Number(control.max) : 100;
              const rawValue = denormalizeSliderValue(desiredLevel, minValue, maxValue);
              if (rawValue == null) {
                return JSON.stringify({
                  "__error": "音量 input の範囲解釈に失敗しました。",
                  "control": describeVolumeControl(control),
                });
              }
              control.focus();
              control.value = String(rawValue);
              control.dispatchEvent(new Event("input", { bubbles: true }));
              control.dispatchEvent(new Event("change", { bubbles: true }));
              return JSON.stringify({
                ok: true,
                level: Math.round(readVolumeLevel() ?? desiredLevel),
                control: describeVolumeControl(control),
              });
            }
            const target = findVolumeBarRoot() || control;
            const rect = target.getBoundingClientRect();
            if (!rect.width || !rect.height) {
              return JSON.stringify({
                "__error": "音量スライダーの描画領域が取得できませんでした。",
                "control": describeVolumeControl(control),
              });
            }
            const clientX = rect.left + (rect.width * (desiredLevel / 100));
            const clientY = rect.top + (rect.height / 2);
            if (target instanceof HTMLElement) {
              target.scrollIntoView({ block: "center", inline: "nearest" });
            }
            dispatchPointerSequence(target, clientX, clientY);
            await sleep(120);
            return JSON.stringify({
              ok: true,
              level: Math.round(readVolumeLevel() ?? desiredLevel),
              control: describeVolumeControl(control),
            });
          } catch (error) {
            return JSON.stringify({ "__error": error.message || String(error) });
          }
        })();
        """
    }

    /// 現在の音量を返す。
    static let fetchVolume = """
    return (async () => {
      try {
        \(sharedSpotifyDOMHelperJS)
        const level = readVolumeLevel();
        if (level == null || Number.isNaN(level)) {
          return JSON.stringify({
            "__error": "音量スライダーが見つかりませんでした。",
            "control": describeVolumeControl(findVolumeControl()),
          });
        }
        return JSON.stringify({
          level: Math.round(level),
          control: describeVolumeControl(findVolumeControl()),
        });
      } catch (error) {
        return JSON.stringify({ "__error": error.message || String(error) });
      }
    })();
    """

    /// プレイヤー状態を返す。
    static let fetchPlayerState = """
    return (async () => {
      try {
        \(sharedSpotifyDOMHelperJS)
        const track = readPlayerTrack();
        return JSON.stringify({
          isPlaying: inferIsPlaying(),
          track,
        });
      } catch (error) {
        return JSON.stringify({ "__error": error.message || String(error) });
      }
    })();
    """

    /// 現在の再生位置を秒単位で返す。
    static let fetchPlaybackPosition = """
    return (async () => {
      try {
        \(sharedSpotifyDOMHelperJS)
        const rawMs = readSeekPositionMs();
        if (rawMs == null) {
          return JSON.stringify({ "__error": "シークバーが見つかりませんでした。" });
        }
        return JSON.stringify({ positionSeconds: msOrSecondsToSeconds(rawMs) });
      } catch (error) {
        return JSON.stringify({ "__error": error.message || String(error) });
      }
    })();
    """

    /// 指定秒数へシークする。シークバーの位置をクリックで操作する。
    static func seekToPosition(_ seconds: Double) -> String {
        """
        return (async () => {
          try {
            \(sharedSpotifyDOMHelperJS)
            const desiredSeconds = \(seconds);
            const rawDurationMs = readSeekDurationMs();
            if (rawDurationMs == null || rawDurationMs <= 0) {
              return JSON.stringify({ "__error": "総再生時間が不明です。" });
            }
            const totalSeconds = msOrSecondsToSeconds(rawDurationMs);
            const ratio = Math.max(0, Math.min(1, desiredSeconds / totalSeconds));
            const targetRoot = findSeekBarRoot();
            if (!targetRoot) {
              return JSON.stringify({ "__error": "シークバーが見つかりませんでした。" });
            }
            const rect = targetRoot.getBoundingClientRect();
            if (!rect.width || !rect.height) {
              return JSON.stringify({ "__error": "シークバーの描画領域が取得できませんでした。" });
            }
            if (targetRoot instanceof HTMLElement) {
              targetRoot.scrollIntoView({ block: "center", inline: "nearest" });
            }
            dispatchPointerSequence(targetRoot, rect.left + rect.width * ratio, rect.top + rect.height / 2);
            await sleep(120);
            return JSON.stringify({ ok: true, ratio });
          } catch (error) {
            return JSON.stringify({ "__error": error.message || String(error) });
          }
        })();
        """
    }
}

private func quotedJSONString(_ value: String) -> String {
    let encoded = try? JSONEncoder().encode(value)
    return encoded.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
}
