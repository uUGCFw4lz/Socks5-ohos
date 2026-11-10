import { Want } from '@kit.AbilityKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import native from 'libentry.so';
import { BUNDLE_NAME, validateServer, writeState, appendDiagnosticLog } from '../model/SocksConfig';

export default class VpnExtAbility extends VpnExtensionAbility {
  private connection: vpnExtension.VpnConnection | undefined = undefined;
  private stopped: boolean = false;
  private phase: string = 'connecting';
  private message: string = '';
  private heartbeat: number = -1;
  private startedAt: number = 0;

  private trace(message: string): void {
    appendDiagnosticLog(this.context, `[VPN +${Date.now() - this.startedAt}ms] ${message}`);
  }

  onCreate(want: Want): void {
    this.startedAt = Date.now();
    this.trace('onCreate build=ipv4-only-5');
    this.stopped = false;
    this.publish();
    this.heartbeat = setInterval(() => this.publish(), 1000);
    this.start(want).catch(async (error: Error) => {
      if (this.stopped) {
        return;
      }
      this.phase = 'failed';
      this.message = error.message || JSON.stringify(error);
      this.trace(`FAILED message=${this.message} detail=${JSON.stringify(error)}`);
      hilog.error(0x3200, 'socks5vpn', '%{public}s', this.message);
      this.publish();
      await this.cleanup();
    });
  }

  onDestroy(): void {
    this.trace('onDestroy');
    this.stopped = true;
    if (this.heartbeat !== -1) {
      clearInterval(this.heartbeat);
      this.heartbeat = -1;
    }
    this.phase = 'disconnected';
    this.message = '';
    this.publish();
    this.cleanup();
  }

  private publish(): void {
    try {
      writeState(this.context, this.phase, this.message);
    } catch (error) {
      hilog.error(0x3200, 'socks5vpn', 'state write failed: %{public}s', JSON.stringify(error));
    }
  }

  private async start(want: Want): Promise<void> {
    const host = want.parameters?.host;
    const port = want.parameters?.port;
    if (typeof host !== 'string' || typeof port !== 'number' || validateServer(host, `${port}`)) {
      throw new Error('无效的 SOCKS5 服务器配置');
    }
    this.trace(`parameters proxy=${host}:${port} mode=IPv4-only`);
    const connection = vpnExtension.createVpnConnection(this.context);
    this.connection = connection;
    this.trace('protectProcessNet BEGIN');
    await connection.protectProcessNet();
    this.trace('protectProcessNet OK');
    if (this.stopped) {
      return;
    }
    const config: vpnExtension.VpnConfig = {
      addresses: [
        { address: { address: '10.0.0.2', family: 1 }, prefixLength: 24 },
        { address: { address: 'fd00:5::2', family: 2 }, prefixLength: 64 }
      ],
      routes: [{
        interface: 'vpn-tun',
        destination: { address: { address: '0.0.0.0', family: 1, port: 0 }, prefixLength: 0 },
        gateway: { address: '10.0.0.1', family: 1, port: 0 },
        hasGateway: true,
        isDefaultRoute: true
      }, {
        interface: 'vpn-tun',
        destination: { address: { address: '::', family: 2, port: 0 }, prefixLength: 0 },
        gateway: { address: 'fd00:5::1', family: 2, port: 0 },
        hasGateway: true,
        isDefaultRoute: true
      }],
      dnsAddresses: ['8.8.8.8', '8.8.4.4'],
      mtu: 1400,
      isIPv4Accepted: true,
      isIPv6Accepted: true,
      blockedApplications: [BUNDLE_NAME]
    };
    this.trace(`create TUN BEGIN config=${JSON.stringify(config)}`);
    const tunFd = await connection.create(config);
    this.trace(`create TUN OK fd=${tunFd}`);
    if (this.stopped) {
      await connection.destroy();
      return;
    }
    const logPath = `${this.context.getApplicationContext().filesDir}/tun2socks.log`;
    this.trace(`NAPI startTun2Socks BEGIN fd=${tunFd} proxy=${host}:${port} logPath=${logPath}`);
    native.startTun2Socks(tunFd, host, port, logPath);
    this.trace('NAPI startTun2Socks OK; stack running, see PROBE and TUN logs for connectivity');
    this.phase = 'connected';
    this.publish();
  }

  private async cleanup(): Promise<void> {
    this.trace('cleanup BEGIN');
    native.stopTun2Socks();
    this.trace('NAPI stopTun2Socks OK');
    const connection = this.connection;
    this.connection = undefined;
    if (connection) {
      try {
        await connection.destroy();
        this.trace('destroy TUN OK');
      } catch (error) {
        this.trace(`destroy TUN FAIL ${JSON.stringify(error)}`);
        hilog.error(0x3200, 'socks5vpn', 'VPN destroy failed: %{public}s', JSON.stringify(error));
      }
    }
  }
}