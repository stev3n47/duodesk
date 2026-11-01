// /api/download?os=win|win-arm64|mac|linux|deb|android|android-full
// Sends the visitor straight to the matching file of the latest DuoDesk release on GitHub, so a
// Download button starts the download instead of opening the release page. File names carry the
// version, so they are looked up from the GitHub API (cached per function instance for 10 min).
const REPO = '0xCodez/DuoDesk';
const PAGE = `https://github.com/${REPO}/releases/latest`;
const TTL = 10 * 60 * 1000;

const PICK = {
  win: (n) => /^DuoDesk-Setup-.*\.exe$/.test(n) && !/-arm64\.exe$/.test(n),
  'win-arm64': (n) => /^DuoDesk-Setup-.*-arm64\.exe$/.test(n),
  mac: (n) => /^DuoDesk-.*-arm64\.dmg$/.test(n),
  linux: (n) => /^DuoDesk-.*\.AppImage$/.test(n),
  deb: (n) => /^DuoDesk-.*\.deb$/.test(n),
  android: (n) => /^DuoDesk-.*\.apk$/.test(n) && !/-full\.apk$/.test(n),
  'android-full': (n) => /^DuoDesk-.*-full\.apk$/.test(n),
  ios: (n) => /^DuoDesk-.*\.ipa$/.test(n),
}

let cache = { at: 0, assets: null };
async function assets() {
  if (cache.assets && Date.now() - cache.at < TTL) return cache.assets;
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { accept: 'application/vnd.github+json', 'user-agent': 'duodesk-site' },
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) throw new Error(`github ${res.status}`);
    const list = (await res.json()).assets || [];
    cache = { at: Date.now(), assets: list.map((a) => ({ name: a.name, url: a.browser_download_url })) };
  } catch {
    // stale beats nothing; null when GitHub never answered
  }
  return cache.assets;
}

export default async function handler(req, res) {
  const os = new URL(req.url, 'http://x').searchParams.get('os') || '';
  const pick = PICK[os];
  const list = pick ? await assets() : null;
  const hit = list && list.find((a) => pick(a.name));
  res.statusCode = 302;
  res.setHeader('location', hit ? hit.url : PAGE);
  res.setHeader('cache-control', 'no-store');
  res.end();
}
