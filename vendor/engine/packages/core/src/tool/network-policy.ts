const localHostnames = new Set(['localhost', 'localhost.localdomain', 'metadata.google.internal'])

export function assertPublicReadOnlyURL(url: URL) {
  if (url.protocol !== 'http:' && url.protocol !== 'https:') throw new Error('URL must use HTTP or HTTPS')
  if (url.username || url.password) throw new Error('Credential-bearing URLs are not allowed')

  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, '')
  if (localHostnames.has(host) || host.endsWith('.localhost') || host.endsWith('.local') || host.endsWith('.internal')) {
    throw new Error('Local and private hostnames are not allowed')
  }
  if (isPrivateIPv4(host) || isPrivateIPv6(host)) throw new Error('Private network addresses are not allowed')
}

export type DNSResult = { address: string; family: number }

/**
 * Apply the same private-target policy to DNS answers, rather than trusting
 * only the hostname syntax. This is the minimum required defence against a
 * public hostname that later resolves to an internal address.
 */
export async function assertPublicReadOnlyTarget(
  url: URL,
  resolve: (hostname: string) => Promise<readonly DNSResult[]>,
) {
  assertPublicReadOnlyURL(url)
  const host = url.hostname.replace(/^\[|\]$/g, '')
  if (isPrivateIPv4(host) || isPrivateIPv6(host)) return

  const answers = await resolve(host)
  if (answers.length === 0) throw new Error('Hostname did not resolve to a public address')
  for (const answer of answers) {
    if (isPrivateIPv4(answer.address) || isPrivateIPv6(answer.address)) {
      throw new Error('Private network addresses are not allowed')
    }
  }
}

function isPrivateIPv4(host: string) {
  const parts = host.split('.')
  if (parts.length !== 4 || parts.some((part) => !/^\d{1,3}$/.test(part))) return false
  const octets = parts.map(Number)
  if (octets.some((value) => value > 255)) return false

  const [first, second] = octets
  if (first === 0 || first === 10 || first === 127) return true
  if (first === 100 && second >= 64 && second <= 127) return true
  if (first === 169 && second === 254) return true
  if (first === 172 && second >= 16 && second <= 31) return true
  if (first === 192 && second === 168) return true
  if (first === 198 && (second === 18 || second === 19)) return true
  return false
}

function isPrivateIPv6(host: string) {
  const normalized = host.toLowerCase()
  if (!normalized.includes(':')) return false
  if (normalized === '::' || normalized === '::1') return true
  if (normalized.startsWith('fe80:') || normalized.startsWith('fc') || normalized.startsWith('fd')) return true
  return normalized.startsWith('::ffff:127.') || normalized.startsWith('::ffff:10.') || normalized.startsWith('::ffff:192.168.')
}
