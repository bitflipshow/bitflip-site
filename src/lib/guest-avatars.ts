const REMOTE_AVATAR_PROTOCOL = /^(https?:)?\/\//i;
const remoteAvatarCache = new Map<string, Promise<string>>();

function toRemoteUrl(avatar: string) {
  return avatar.startsWith("//") ? `https:${avatar}` : avatar;
}

async function fetchAvatarAsDataUrl(url: string) {
  const response = await fetch(url, {
    headers: {
      accept: "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
      "user-agent": "BitFlip.show avatar resolver",
    },
  });

  if (!response.ok) {
    throw new Error(`Failed to fetch avatar: ${response.status} ${response.statusText}`);
  }

  const contentType = response.headers.get("content-type") || "application/octet-stream";
  if (!contentType.startsWith("image/")) {
    throw new Error(`Avatar response was not an image: ${contentType}`);
  }

  const bytes = Buffer.from(await response.arrayBuffer());
  return `data:${contentType};base64,${bytes.toString("base64")}`;
}

export async function resolveGuestAvatarSrc(avatar?: string) {
  if (!avatar) return undefined;
  if (!REMOTE_AVATAR_PROTOCOL.test(avatar)) return `/images/guests/${avatar}`;

  const remoteUrl = toRemoteUrl(avatar);
  const cached = remoteAvatarCache.get(remoteUrl);
  if (cached) return cached;

  const pending = fetchAvatarAsDataUrl(remoteUrl).catch((error) => {
    console.warn(`Unable to inline guest avatar from ${remoteUrl}:`, error);
    return remoteUrl;
  });

  remoteAvatarCache.set(remoteUrl, pending);
  return pending;
}
