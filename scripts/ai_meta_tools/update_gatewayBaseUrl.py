filepath = "repos/gui/src/services/gatewayBaseUrl.ts"
content = """const trimTrailingSlash = (value: string): string => value.replace(/\\/+$/, "");

function isLocalHost(hostname: string): boolean {
  return hostname === "localhost" || hostname === "127.0.0.1";
}

function inferGatewayHostname(hostname: string): string {
  if (hostname === "gateway.mestumre.dev" || hostname.startsWith("gateway.")) {
    return hostname;
  }

  const strippedHost = hostname.replace(/^(www\\.|gui\\.)/i, "");
  return `gateway.${strippedHost}`;
}

export function resolveApiMode(): "gateway" | "direct" {
  const envMode = import.meta.env.VITE_API_MODE;
  return envMode === "direct" ? "direct" : "gateway";
}

export function resolveGatewayBaseUrl(): string {
  const envValue = import.meta.env.VITE_API_BASE_URL || import.meta.env.VITE_GATEWAY_URL;
  if (envValue && envValue.trim().length > 0) {
    return trimTrailingSlash(envValue.trim());
  }

  const { hostname, protocol, origin } = window.location;

  if (isLocalHost(hostname)) {
    return resolveApiMode() === "direct" ? "http://localhost:8082" : "http://localhost:8090";
  }

  const inferredGatewayHost = inferGatewayHostname(hostname);
  if (inferredGatewayHost === hostname) {
    return trimTrailingSlash(origin);
  }

  return trimTrailingSlash(`${protocol}//${inferredGatewayHost}`);
}
"""
with open(filepath, "w") as f:
    f.write(content)
print("Updated successfully")
