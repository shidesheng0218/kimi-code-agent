export function nativeRuntimeResourceNames(): string[];
export function nativeNodeDistribution(nodeVersion: string, arch?: string): {
  archiveName: string;
  archiveURL: string;
  checksumsURL: string;
};
export function nativeArtifactPaths(rootDir: string, arch?: string): {
  application: string;
  executable: string;
  resources: string;
};
export function releaseVerificationCommands(input: {
  appPath: string;
  dmgPath: string;
  zipPath: string;
}): Array<[string, string[]]>;
export function swiftBuildArgs(arch?: string, extraArgs?: string[]): string[];
export function codesignArgs(input: { appPath: string; identity: string }): string[];
export function resolveCodesignIdentity(env?: Record<string, string | undefined>): {
  identity: string | undefined;
  source: 'developer-id' | 'local' | 'adhoc';
};
export function notarizationSubmitArgs(input: { dmgPath: string; keychainProfile: string }): string[];
export function packageNativeMacOS(rootDir?: string): Promise<{
  application: string;
  dmgPath: string;
  zipPath: string;
}>;
