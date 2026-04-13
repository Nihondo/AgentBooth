// MARK: - YouTubeMusicJSScripts.swift
// YouTube Music 内部 API 呼び出しおよびプレイヤー制御に使用する JavaScript 定数。
//
// 認証方式:
//   YouTube Music の内部 API は Cookie だけでなく Authorization: SAPISIDHASH ヘッダーが必要。
//   SAPISIDHASH = "SAPISIDHASH {timestamp}_{SHA1(timestamp + " " + SAPISID + " " + origin)}"
//   SAPISID は __Secure-3PAPISID クッキーから取得（HTTPS コンテキスト）。
//   ytmusicapi (sigma67) の get_sapisid_hash と同じアルゴリズム。
//
// パス仕様 (ytmusicapi 準拠):
//   playlistId: musicTwoRowItemRenderer.title.runs[0].navigationEndpoint.browseEndpoint.browseId
//   videoId:    musicResponsiveListItemRenderer.playlistItemData.videoId

import Foundation

// MARK: - 共通ヘルパー JS（各スクリプト内でインライン展開）

private let sharedHelperJS = """
// ytcfg からコンテキストを構築（失敗しても空オブジェクトで続行）
function buildContext() {
  const cfg = (window.ytcfg && window.ytcfg.data_) || {};
  return {
    client: {
      clientName: "WEB_REMIX",
      clientVersion: cfg.INNERTUBE_CLIENT_VERSION || "1.20240101.00.00",
      hl: cfg.HL || "ja",
      gl: cfg.GL || "JP"
    }
  };
}

// /youtubei/v1/browse の URL（API キーを付与）
function browseUrl() {
  const cfg = (window.ytcfg && window.ytcfg.data_) || {};
  const key = cfg.INNERTUBE_API_KEY || "";
  return "/youtubei/v1/browse" + (key ? "?key=" + key : "");
}

// SAPISIDHASH を計算して Authorization ヘッダー値を返す
// SAPISID = __Secure-3PAPISID クッキー（HTTPS）、なければ SAPISID にフォールバック
async function buildAuthHeader(origin) {
  function readCookie(name) {
    const m = document.cookie.match(new RegExp("(?:^|; )" + name + "=([^;]*)"));
    return m ? decodeURIComponent(m[1]) : null;
  }
  const sapisid = readCookie("__Secure-3PAPISID") || readCookie("SAPISID");
  if (!sapisid) return null;
  const timestamp = Math.floor(Date.now() / 1000);
  const message = timestamp + " " + sapisid + " " + origin;
  const msgBuf = new TextEncoder().encode(message);
  const hashBuf = await crypto.subtle.digest("SHA-1", msgBuf);
  const hashHex = Array.from(new Uint8Array(hashBuf))
    .map(b => b.toString(16).padStart(2, "0")).join("");
  return "SAPISIDHASH " + timestamp + "_" + hashHex;
}

// 認証済み POST リクエストを送信する
async function ytmFetch(url, body) {
  const origin = "https://music.youtube.com";
  const auth = await buildAuthHeader(origin);
  const headers = {
    "Content-Type": "application/json",
    "X-Goog-AuthUser": "0",
    "x-origin": origin
  };
  if (auth) headers["Authorization"] = auth;
  const response = await fetch(url, {
    method: "POST",
    credentials: "include",
    headers,
    body: JSON.stringify(body)
  });
  if (!response.ok) throw new Error("HTTP " + response.status);
  return response.json();
}
"""

/// YouTube Music JS スクリプト群
enum YouTubeMusicJSScripts {

    // MARK: - デバッグ: 生レスポンスダンプ

    /// FEmusic_liked_playlists のレスポンス構造を返す（デバッグ用）
    static let debugDumpPlaylists = """
    return (async () => {
      try {
        \(sharedHelperJS)
        const data = await ytmFetch(browseUrl(), {
          browseId: "FEmusic_liked_playlists",
          context: buildContext()
        });
        const tabs = data?.contents?.singleColumnBrowseResultsRenderer?.tabs;
        const sections = tabs?.[0]?.tabRenderer?.content?.sectionListRenderer?.contents || [];
        const summary = {
          sectionCount: sections.length,
          sections: sections.map(s => {
            const topKey = Object.keys(s)[0];
            const inner = s[topKey] || {};
            return {
              key: topKey,
              innerKeys: Object.keys(inner),
              contents: inner.contents
                ? inner.contents.slice(0, 3).map(c => {
                    const ck = Object.keys(c)[0];
                    return { key: ck, innerKeys: Object.keys(c[ck] || {}) };
                  })
                : null,
              items: inner.items
                ? inner.items.slice(0, 2).map(i => {
                    const ik = Object.keys(i)[0];
                    return { key: ik, innerKeys: Object.keys(i[ik] || {}) };
                  })
                : null
            };
          })
        };
        return JSON.stringify(summary);
      } catch (e) {
        return JSON.stringify({ "__error": e.message || String(e) });
      }
    })();
    """

    // MARK: - デバッグ: トラック取得構造ダンプ

    /// 指定プレイリストのトラック取得レスポンス構造を返す（デバッグ用）
    static func debugDumpTracks(playlistId: String) -> String {
        """
        return (async () => {
          try {
            \(sharedHelperJS)
            const data = await ytmFetch(browseUrl(), {
              browseId: "VL\(playlistId)",
              context: buildContext()
            });

            // twoColumn の secondaryContents を深掘り
            const sections =
              data?.contents?.twoColumnBrowseResultsRenderer
                ?.secondaryContents?.sectionListRenderer?.contents ||
              data?.contents?.singleColumnBrowseResultsRenderer
                ?.tabs?.[0]?.tabRenderer?.content
                ?.sectionListRenderer?.contents || [];

            const summary = {
              topContentKeys: Object.keys(data?.contents || {}),
              sectionCount: sections.length,
              sections: sections.map(s => {
                const topKey = Object.keys(s)[0];
                const inner = s[topKey] || {};
                return {
                  key: topKey,
                  innerKeys: Object.keys(inner),
                  contentsLen: inner.contents ? inner.contents.length : null,
                  firstItemKey: inner.contents?.[0] ? Object.keys(inner.contents[0])[0] : null,
                  firstItemFields: inner.contents?.[0]
                    ? Object.keys(inner.contents[0][Object.keys(inner.contents[0])[0]] || {})
                    : null
                };
              })
            };
            return JSON.stringify(summary);
          } catch (e) {
            return JSON.stringify({ "__error": e.message || String(e) });
          }
        })();
        """
    }

    // MARK: - プレイリスト一覧

    /// ユーザーのプレイリスト一覧を取得する
    /// 返却形式: [{ "id": "PLxxx", "title": "プレイリスト名" }]
    static let fetchPlaylists = """
    return (async () => {
      try {
        \(sharedHelperJS)
        const data = await ytmFetch(browseUrl(), {
          browseId: "FEmusic_liked_playlists",
          context: buildContext()
        });

        const sections =
          data?.contents?.singleColumnBrowseResultsRenderer
            ?.tabs?.[0]?.tabRenderer?.content
            ?.sectionListRenderer?.contents || [];

        // gridRenderer を持つセクションを探す（itemSectionRenderer の中にある場合も対応）
        let gridItems = [];
        for (const section of sections) {
          // 直接 gridRenderer
          if (section?.gridRenderer?.items) {
            gridItems = section.gridRenderer.items;
            break;
          }
          // itemSectionRenderer → contents → gridRenderer
          const innerContents = section?.itemSectionRenderer?.contents || [];
          for (const inner of innerContents) {
            if (inner?.gridRenderer?.items) {
              gridItems = inner.gridRenderer.items;
              break;
            }
          }
          if (gridItems.length > 0) break;
        }

        const items = [];
        // items[0] は "Liked Music" など自動プレイリストのため除外
        for (const item of gridItems.slice(1)) {
          const r = item?.musicTwoRowItemRenderer;
          if (!r) continue;
          const title = r.title?.runs?.[0]?.text;
          if (!title) continue;
          // playlistId: title.runs[0].navigationEndpoint.browseEndpoint.browseId (ytmusicapi 準拠)
          const browseId =
            r.title?.runs?.[0]?.navigationEndpoint?.browseEndpoint?.browseId ||
            r.overlay?.musicItemThumbnailOverlayRenderer?.content
              ?.musicPlayButtonRenderer?.playNavigationEndpoint?.watchEndpoint?.playlistId;
          if (!browseId) continue;
          const playlistId = browseId.startsWith("VL") ? browseId.slice(2) : browseId;
          items.push({ id: playlistId, title });
        }
        return JSON.stringify(items);
      } catch (e) {
        return JSON.stringify({ "__error": e.message || String(e) });
      }
    })();
    """

    // MARK: - トラック一覧

    /// 指定プレイリスト内のトラック一覧を取得する
    /// 返却形式: [{ "videoId": "xxx", "title": "曲名", "artist": "アーティスト", "album": "アルバム", "durationSeconds": 240 }]
    static func fetchTracks(playlistId: String) -> String {
        """
        return (async () => {
          try {
            \(sharedHelperJS)
            const data = await ytmFetch(browseUrl(), {
              browseId: "VL\(playlistId)",
              context: buildContext()
            });

            // プレイリスト詳細は twoColumnBrowseResultsRenderer を使用
            // secondaryContents.sectionListRenderer にトラック一覧が入る
            const sections =
              data?.contents?.twoColumnBrowseResultsRenderer
                ?.secondaryContents?.sectionListRenderer?.contents ||
              data?.contents?.singleColumnBrowseResultsRenderer
                ?.tabs?.[0]?.tabRenderer?.content
                ?.sectionListRenderer?.contents || [];

            let rawItems = [];
            for (const section of sections) {
              const shelf = section?.musicShelfRenderer || section?.musicPlaylistShelfRenderer;
              if (shelf?.contents) { rawItems = shelf.contents; break; }
              const innerContents = section?.itemSectionRenderer?.contents || [];
              for (const inner of innerContents) {
                const s = inner?.musicShelfRenderer || inner?.musicPlaylistShelfRenderer;
                if (s?.contents) { rawItems = s.contents; break; }
              }
              if (rawItems.length > 0) break;
            }

            const tracks = [];
            for (const item of rawItems) {
              const r = item?.musicResponsiveListItemRenderer;
              if (!r) continue;
              const col0 = r.flexColumns?.[0]?.musicResponsiveListItemFlexColumnRenderer;
              const videoId =
                r.playlistItemData?.videoId ||
                col0?.text?.runs?.[0]?.navigationEndpoint?.watchEndpoint?.videoId ||
                r.overlay?.musicItemThumbnailOverlayRenderer?.content
                  ?.musicPlayButtonRenderer?.playNavigationEndpoint?.watchEndpoint?.videoId;
              if (!videoId) continue;
              const title = col0?.text?.runs?.[0]?.text || "";
              const col1Runs = r.flexColumns?.[1]
                ?.musicResponsiveListItemFlexColumnRenderer?.text?.runs || [];
              const artist = col1Runs[0]?.text || "";
              const album =
                col1Runs[2]?.text ||
                r.flexColumns?.[2]?.musicResponsiveListItemFlexColumnRenderer
                  ?.text?.runs?.[0]?.text || "";
              const durationText =
                r.fixedColumns?.[0]?.musicResponsiveListItemFixedColumnRenderer
                  ?.text?.runs?.[0]?.text || "0:00";
              tracks.push({ videoId, title, artist, album, durationSeconds: parseDuration(durationText) });
            }
            return JSON.stringify(tracks);
          } catch (e) {
            return JSON.stringify({ "__error": e.message || String(e) });
          }

          function parseDuration(text) {
            const parts = text.split(":").map(Number);
            if (parts.length === 2) return parts[0] * 60 + parts[1];
            if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
            return 0;
          }
        })();
        """
    }

    // MARK: - 再生制御

    static func playTrack(videoId: String, playlistId: String) -> String {
        """
        return (async () => {
          try {
            window.location.href = "https://music.youtube.com/watch?v=\(videoId)&list=\(playlistId)";
            return JSON.stringify({ ok: true });
          } catch (e) {
            return JSON.stringify({ "__error": e.message || String(e) });
          }
        })();
        """
    }

    static let stopPlayback = """
    return (async () => {
      try {
        const v = document.querySelector('video');
        if (v) { v.pause(); v.currentTime = 0; }
        return JSON.stringify({ ok: true });
      } catch (e) { return JSON.stringify({ "__error": e.message || String(e) }); }
    })();
    """

    static let pausePlayback = """
    return (async () => {
      try {
        document.querySelector('video')?.pause();
        return JSON.stringify({ ok: true });
      } catch (e) { return JSON.stringify({ "__error": e.message || String(e) }); }
    })();
    """

    static let resumePlayback = """
    return (async () => {
      try {
        const v = document.querySelector('video');
        if (v) await v.play();
        return JSON.stringify({ ok: true });
      } catch (e) { return JSON.stringify({ "__error": e.message || String(e) }); }
    })();
    """

    static func setVolume(_ level: Int) -> String {
        let clamped = max(0, min(100, level))
        return """
        return (async () => {
          try {
            const v = document.querySelector('video');
            if (v) v.volume = \(clamped) / 100.0;
            return JSON.stringify({ ok: true });
          } catch (e) { return JSON.stringify({ "__error": e.message || String(e) }); }
        })();
        """
    }

    static let fetchVolume = """
    return (async () => {
      try {
        const v = document.querySelector('video');
        return JSON.stringify({ level: v ? Math.round(v.volume * 100) : 0 });
      } catch (e) { return JSON.stringify({ "__error": e.message || String(e) }); }
    })();
    """

    static let fetchIsPlaying = """
    return (async () => {
      try {
        const v = document.querySelector('video');
        const isPlaying = v ? !v.paused && !v.ended && v.readyState > 2 : false;
        return JSON.stringify({ isPlaying });
      } catch (e) { return JSON.stringify({ "__error": e.message || String(e) }); }
    })();
    """

    static let fetchCurrentTrack = """
    return (async () => {
      try {
        const bar = document.querySelector('ytmusic-player-bar');
        if (!bar) return JSON.stringify(null);
        const title = bar.querySelector('.title.ytmusic-player-bar')?.textContent?.trim() || "";
        if (!title) return JSON.stringify(null);
        const byline = bar.querySelector('.byline.ytmusic-player-bar');
        const artist = byline?.querySelector('a')?.textContent?.trim()
          || byline?.textContent?.trim() || "";
        const videoId = new URLSearchParams(window.location.search).get('v') || "";
        const v = document.querySelector('video');
        const durationSeconds = v ? Math.round(v.duration) || 0 : 0;
        return JSON.stringify({ videoId, title, artist, album: "", durationSeconds });
      } catch (e) { return JSON.stringify({ "__error": e.message || String(e) }); }
    })();
    """

    // MARK: - 再生位置

    /// 現在の再生位置を秒単位で返す
    static let fetchPlaybackPosition = """
    return (async () => {
      try {
        const v = document.querySelector('video');
        return JSON.stringify({ positionSeconds: v ? (v.currentTime || 0) : 0 });
      } catch (e) { return JSON.stringify({ "__error": e.message || String(e) }); }
    })();
    """

    /// 指定秒数へシークする
    static func seekToPosition(_ seconds: Double) -> String {
        """
        return (async () => {
          try {
            const v = document.querySelector('video');
            if (v) v.currentTime = \(seconds);
            return JSON.stringify({ ok: true });
          } catch (e) { return JSON.stringify({ "__error": e.message || String(e) }); }
        })();
        """
    }
}
