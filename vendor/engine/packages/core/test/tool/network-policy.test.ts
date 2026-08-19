import { describe, expect, test } from 'bun:test'
import { assertPublicReadOnlyTarget, assertPublicReadOnlyURL } from '../../src/tool/network-policy'

describe('Kimi public read-only network policy', () => {
  test('allows an HTTPS public URL without credentials', () => {
    expect(() => assertPublicReadOnlyURL(new URL('https://docs.example.com/reference'))).not.toThrow()
  })

  test('rejects private, loopback, local and credential-bearing URLs', () => {
    for (const value of [
      'http://127.0.0.1:8080',
      'https://10.0.0.1/internal',
      'https://192.168.1.20/private',
      'https://[::1]/health',
      'https://service.local/status',
      'https://user:password@example.com/private',
      'file:///etc/hosts'
    ]) {
      expect(() => assertPublicReadOnlyURL(new URL(value))).toThrow()
    }
  })

  test('rejects hostnames that resolve to a private address before a fetch begins', async () => {
    await expect(
      assertPublicReadOnlyTarget(new URL('https://rebind.example'), async () => [{ address: '10.0.0.3', family: 4 }]),
    ).rejects.toThrow('Private network addresses')
  })

  test('allows hostnames that resolve exclusively to public addresses', async () => {
    await expect(
      assertPublicReadOnlyTarget(new URL('https://docs.example.com'), async () => [{ address: '93.184.216.34', family: 4 }]),
    ).resolves.toBeUndefined()
  })
})
