const NativeMock: Record<string, Object> = {
  'startTun2Socks': (fd: number, host: string, port: number, logPath: string): void => {},
  'stopTun2Socks': (): void => {},
};

export default NativeMock;