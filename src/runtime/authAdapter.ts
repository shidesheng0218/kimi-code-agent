import { login, type LoginOptions, type LoginResult } from '@moonshot-ai/kimi-agent-sdk';

export type LoginImplementation = (options: LoginOptions) => Promise<LoginResult>;
export type OpenUrl = (url: string) => Promise<void>;

export async function runKimiLogin(
  executable: string,
  openUrl: OpenUrl,
  loginImplementation: LoginImplementation = login
): Promise<LoginResult> {
  return loginImplementation({
    executable,
    onUrl: url => {
      void openUrl(url);
    }
  });
}
