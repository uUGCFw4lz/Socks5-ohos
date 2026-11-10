import { common, Want, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { BUNDLE_NAME, VPN_ABILITY, readState,
  appendDiagnosticLog, readDiagnosticLog } from '../model/SocksConfig';
import { ServerProfile, ServerStore, validateProfile, removeServer } from '../model/ServerStore';
import { ThemeMode, ThemePalette, ThemeStore, LIGHT_THEME, DARK_THEME, resolveTheme } from '../model/ThemeStore';

@Entry
@Component
struct Index {
  @State servers: ServerProfile[] = [];
  @State selectedId: string = '';
  @State editing: boolean = false;
  @State editId: string = '';
  @State editName: string = '';
  @State editHost: string = '';
  @State editPort: string = '1080';
  @State formError: string = '';
  @State saving: boolean = false;
  @State themeMode: ThemeMode = 'system';
  @State colorMode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  @State changingTheme: boolean = false;
  @State phase: string = 'disconnected';
  @State error: string = '';
  @State busy: boolean = false;
  @State ready: boolean = false;
  @State logs: string = '';
  @State showLogs: boolean = false;
  @State copyStatus: string = '';
  private timer: number = -1;
  private requestTime: number = 0;
  private observer: vpnExtension.VpnObserver | undefined = undefined;
  private environmentId: number = -1;

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    this.observeTheme();
    this.loadTheme();
    this.load();
    this.poll();
    this.timer = setInterval(() => this.poll(), 1000);
    try {
      this.observer = vpnExtension.createVpnObserver();
      this.observer.onAuthorizationResult((allowed: boolean) => {
        appendDiagnosticLog(this.context(), `[UI authorization] allowed=${allowed}`);
        if (!allowed) {
          this.requestTime = 0;
          this.phase = 'disconnected';
          this.error = 'VPN 授权已取消';
        }
      });
    } catch (_) {
    }
  }

  aboutToDisappear(): void {
    clearInterval(this.timer);
    if (this.environmentId !== -1) {
      try {
        this.context().getApplicationContext().off('environment', this.environmentId).catch(() => {});
      } catch (_) {
      }
      this.environmentId = -1;
    }
    try {
      this.observer?.offAuthorizationResult();
    } catch (_) {
    }
  }

  onBackPress(): boolean {
    if (this.editing) {
      this.closeEditor();
      return true;
    }
    if (this.showLogs) {
      this.showLogs = false;
      return true;
    }
    return false;
  }

  private colors(): ThemePalette {
    return resolveTheme(this.themeMode, this.colorMode) === 'dark' ? DARK_THEME : LIGHT_THEME;
  }

  private themeLabel(): string {
    return this.themeMode === 'system' ? '跟随系统' : (this.themeMode === 'dark' ? '深色' : '浅色');
  }

  private observeTheme(): void {
    this.colorMode = this.context().config.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    try {
      this.environmentId = this.context().getApplicationContext().on('environment', {
        onConfigurationUpdated: (config: Configuration): void => {
          if (config.colorMode !== undefined) {
            this.colorMode = config.colorMode;
          }
        },
        onMemoryLevel: (): void => {}
      });
    } catch (_) {
      appendDiagnosticLog(this.context(), '[UI] theme environment listener failed');
    }
  }

  private async loadTheme(): Promise<void> {
    this.changingTheme = true;
    try {
      this.themeMode = await ThemeStore.mode(this.context());
      ThemeStore.apply(this.context(), this.themeMode);
      this.colorMode = this.context().config.colorMode ?? this.colorMode;
    } catch (_) {
      this.error = '无法读取主题设置';
    } finally {
      this.changingTheme = false;
    }
  }

  private async changeTheme(next: ThemeMode): Promise<void> {
    if (this.changingTheme || next === this.themeMode) {
      return;
    }
    this.changingTheme = true;
    const previous = this.themeMode;
    this.themeMode = next;
    try {
      await ThemeStore.save(this.context(), next);
      this.colorMode = this.context().config.colorMode ?? this.colorMode;
    } catch (_) {
      this.themeMode = previous;
      this.error = '主题设置保存失败';
    } finally {
      this.changingTheme = false;
    }
  }

  private async load(): Promise<void> {
    try {
      const settings = await ServerStore.load(this.context());
      this.servers = settings.servers;
      this.selectedId = settings.selectedId;
      this.ready = true;
    } catch (_) {
      this.error = '无法读取已保存的服务器配置';
    }
  }

  private selected(): ServerProfile | undefined {
    return this.servers.find((server: ServerProfile) => server.id === this.selectedId);
  }

  private canManage(): boolean {
    return this.ready && !this.active() && !this.busy && !this.saving;
  }

  private async choose(server: ServerProfile): Promise<void> {
    if (!this.canManage() || server.id === this.selectedId) {
      return;
    }
    this.busy = true;
    try {
      await ServerStore.save(this.context(), { servers: this.servers, selectedId: server.id });
      this.selectedId = server.id;
      this.error = '';
    } catch (_) {
      this.error = '服务器选择保存失败';
    } finally {
      this.busy = false;
    }
  }

  private openEditor(server?: ServerProfile): void {
    if (!this.canManage()) {
      return;
    }
    this.editId = server?.id ?? '';
    this.editName = server?.name ?? '';
    this.editHost = server?.host ?? '';
    this.editPort = `${server?.port ?? 1080}`;
    this.formError = '';
    this.editing = true;
  }

  private closeEditor(): void {
    if (!this.saving) {
      this.editing = false;
      this.formError = '';
    }
  }

  private async saveProfile(): Promise<void> {
    if (!this.canManage()) {
      return;
    }
    let newId = `${Date.now()}`;
    while (this.servers.some((server: ServerProfile) => server.id === newId)) {
      newId = `${Number(newId) + 1}`;
    }
    const server: ServerProfile = {
      id: this.editId || newId, name: this.editName.trim(), host: this.editHost.trim(),
      port: /^\d+$/.test(this.editPort.trim()) ? Number(this.editPort.trim()) : 0
    };
    this.formError = validateProfile(server);
    if (this.formError) {
      return;
    }
    this.saving = true;
    const servers = this.editId ? this.servers.map((item: ServerProfile) => item.id === server.id ? server : item) :
      this.servers.concat([server]);
    const selectedId = this.selectedId || server.id;
    try {
      await ServerStore.save(this.context(), { servers: servers, selectedId: selectedId });
      this.servers = servers;
      this.selectedId = selectedId;
      this.editing = false;
      this.error = '';
    } catch (_) {
      this.formError = '保存失败，请重试';
    } finally {
      this.saving = false;
    }
  }

  private confirmDelete(server: ServerProfile): void {
    if (!this.canManage()) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '删除服务器', message: `删除“${server.name}”？`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', fontColor: this.colors().danger, action: () => { this.deleteProfile(server.id); } }
    });
  }

  private async deleteProfile(id: string): Promise<void> {
    if (!this.canManage()) {
      return;
    }
    this.busy = true;
    const settings = removeServer({ servers: this.servers, selectedId: this.selectedId }, id);
    try {
      await ServerStore.save(this.context(), settings);
      this.servers = settings.servers;
      this.selectedId = settings.selectedId;
      this.error = '';
    } catch (_) {
      this.error = '删除失败，请重试';
    } finally {
      this.busy = false;
    }
  }

  private active(): boolean {
    return this.phase === 'connected' || this.phase === 'connecting';
  }

  private poll(): void {
    if (this.showLogs) {
      this.logs = readDiagnosticLog(this.context());
    }
    const state = readState(this.context());
    if (this.busy) {
      return;
    }
    if (this.requestTime > state.updatedAt) {
      if (Date.now() - this.requestTime < 30000) {
        return;
      }
      this.requestTime = 0;
      this.error = 'VPN 启动超时，请断开后重试';
      return;
    }
    this.phase = state.phase;
    if (state.phase === 'failed') {
      this.error = state.message;
    }
  }

  private async toggle(): Promise<void> {
    if (this.busy || this.saving || (!this.ready && !this.active())) {
      return;
    }
    const want: Want = { bundleName: BUNDLE_NAME, abilityName: VPN_ABILITY };
    const disconnect = this.active();
    this.busy = true;
    this.error = '';
    try {
      if (disconnect) {
        appendDiagnosticLog(this.context(), '[UI] stopVpnExtensionAbility BEGIN');
        await vpnExtension.stopVpnExtensionAbility(want);
        appendDiagnosticLog(this.context(), '[UI] stopVpnExtensionAbility returned');
        this.requestTime = 0;
        this.phase = 'disconnected';
      } else {
        const server = this.selected();
        if (!server) {
          this.error = '请选择服务器';
          return;
        }
        this.error = validateProfile(server);
        if (this.error) {
          return;
        }
        if (this.phase === 'failed') {
          await vpnExtension.stopVpnExtensionAbility(want);
        }
        want.parameters = { host: server.host, port: server.port };
        appendDiagnosticLog(this.context(), `[UI] startVpnExtensionAbility BEGIN proxy=${server.host}:${server.port}`);
        this.requestTime = Date.now();
        this.phase = 'connecting';
        await vpnExtension.startVpnExtensionAbility(want);
        appendDiagnosticLog(this.context(), '[UI] startVpnExtensionAbility returned (await VPN state)');
      }
    } catch (error) {
      appendDiagnosticLog(this.context(), `[UI] toggle FAILED ${JSON.stringify(error)}`);
      this.requestTime = 0;
      this.phase = disconnect ? 'connected' : 'failed';
      this.error = JSON.stringify(error);
    } finally {
      this.busy = false;
    }
  }

  private readLogs(): void {
    this.showLogs = !this.showLogs;
    this.copyStatus = '';
    if (this.showLogs) {
      this.logs = readDiagnosticLog(this.context());
    }
  }

  private async copyLogs(): Promise<void> {
    try {
      this.logs = readDiagnosticLog(this.context());
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logs));
      this.copyStatus = '已复制';
    } catch (_) {
      this.copyStatus = '复制失败';
    }
  }

  @Builder
  private fieldLabel(title: string) {
    Text(title).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.colors().secondaryText)
      .width('100%').margin({ top: 20, bottom: 8 })
  }

  @Builder
  private editor() {
    Column() {
      Text(this.editId ? '编辑服务器' : '新建服务器').fontSize(24).fontWeight(FontWeight.Bold)
        .fontColor(this.colors().text).width('100%').margin({ bottom: 12 })
      Scroll() {
        Column() {
          this.fieldLabel('名称')
          TextInput({ text: this.editName, placeholder: '服务器名称' }).maxLength(48)
            .fontColor(this.colors().text).placeholderColor(this.colors().mutedText).backgroundColor(this.colors().input)
            .height(48).borderRadius(6).enabled(!this.saving).onChange((value: string) => this.editName = value)
          this.fieldLabel('服务器地址')
          TextInput({ text: this.editHost, placeholder: 'IPv4 地址或域名' }).maxLength(253)
            .fontColor(this.colors().text).placeholderColor(this.colors().mutedText).backgroundColor(this.colors().input)
            .height(48).borderRadius(6).enabled(!this.saving).onChange((value: string) => this.editHost = value)
          this.fieldLabel('端口')
          TextInput({ text: this.editPort, placeholder: '1080' }).type(InputType.Number).maxLength(5)
            .fontColor(this.colors().text).placeholderColor(this.colors().mutedText).backgroundColor(this.colors().input)
            .height(48).borderRadius(6).enabled(!this.saving).onChange((value: string) => this.editPort = value)
          if (this.formError) {
            Text(this.formError).fontSize(13).fontColor(this.colors().danger).width('100%').margin({ top: 16 })
          }
        }.width('100%').padding({ bottom: 24 })
      }.width('100%').layoutWeight(1).align(Alignment.TopStart)
      Row({ space: 12 }) {
        Button('取消', { type: ButtonType.Normal }).layoutWeight(1).height(48).borderRadius(6)
          .backgroundColor(this.colors().secondaryButton).fontColor(this.colors().text)
          .enabled(!this.saving).onClick(() => this.closeEditor())
        Button(this.saving ? '保存中' : '保存服务器', { type: ButtonType.Normal }).layoutWeight(2).height(48).borderRadius(6)
          .backgroundColor(this.colors().accent).fontColor(this.colors().onAccent)
          .enabled(this.canManage()).onClick(() => this.saveProfile())
      }.width('100%').padding({ top: 16 })
    }.width('100%').height('100%')
  }

  @Builder
  private serverRow(server: ServerProfile) {
    Row({ space: 8 }) {
      Radio({ value: server.id, group: 'servers' }).checked(server.id === this.selectedId)
        .radioStyle({ checkedBackgroundColor: this.colors().accent }).enabled(this.canManage())
        .accessibilityText(`选择 ${server.name}`).onChange((checked: boolean) => { if (checked) { this.choose(server); } })
      Column({ space: 6 }) {
        Text(server.name).fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(`${server.host}:${server.port}`).fontSize(13).fontColor(this.colors().secondaryText)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start).onClick(() => this.choose(server))
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.pencil_line')).fontSize(20).fontColor([this.colors().secondaryText])
      }.width(40).height(44).borderRadius(6).backgroundColor(Color.Transparent)
        .accessibilityText(`编辑 ${server.name}`).bindTips('编辑服务器').enabled(this.canManage())
        .onClick(() => this.openEditor(server))
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.ohos_trash')).fontSize(20).fontColor([this.colors().secondaryText])
      }.width(40).height(44).borderRadius(6).backgroundColor(Color.Transparent)
        .accessibilityText(`删除 ${server.name}`).bindTips('删除服务器').enabled(this.canManage())
        .onClick(() => this.confirmDelete(server))
    }.width('100%').padding({ top: 18, bottom: 18, left: 6, right: 6 })
      .backgroundColor(server.id === this.selectedId ? this.colors().selectedRow : Color.Transparent)
      .border({ width: { bottom: 1 }, color: this.colors().border })
  }

  @Builder
  private logPage() {
    Column() {
      Row({ space: 8 }) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([this.colors().text])
        }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('返回')
          .bindTips('返回').onClick(() => this.showLogs = false)
        Text('连接日志').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.colors().text).layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(22).fontColor([this.colors().secondaryText])
        }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('刷新日志')
          .bindTips('刷新日志').onClick(() => { this.logs = readDiagnosticLog(this.context()); })
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.plus_square_on_square')).fontSize(22).fontColor([this.colors().secondaryText])
        }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('复制日志')
          .bindTips('复制日志').onClick(() => this.copyLogs())
      }.width('100%')
      if (this.copyStatus) {
        Text(this.copyStatus).fontSize(13).fontColor(this.colors().secondaryText).width('100%').margin({ top: 8 })
      }
      Scroll() {
        Text(this.logs).fontSize(12).fontFamily('monospace').fontColor(this.colors().secondaryText)
          .width('100%').copyOption(CopyOptions.InApp)
      }.width('100%').layoutWeight(1).margin({ top: 16 }).align(Alignment.TopStart)
    }.width('100%').height('100%')
  }

  @Builder
  private home() {
    Column() {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.ohos_lock')).fontSize(28).fontColor([this.colors().accent])
        Text('SOCKS5').fontSize(26).fontWeight(FontWeight.Bold).fontColor(this.colors().text).layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph(resolveTheme(this.themeMode, this.colorMode) === 'dark' ? $r('sys.symbol.moon') : $r('sys.symbol.sun_max'))
            .fontSize(22).fontColor([this.colors().text])
        }.width(44).height(44).borderRadius(6).backgroundColor(this.colors().secondaryButton)
          .accessibilityText(`主题：${this.themeLabel()}`).bindTips(`主题：${this.themeLabel()}`)
          .enabled(!this.changingTheme)
          .bindMenu([
            { value: this.themeMode === 'system' ? '跟随系统（当前）' : '跟随系统', action: () => { this.changeTheme('system'); } },
            { value: this.themeMode === 'light' ? '浅色（当前）' : '浅色', action: () => { this.changeTheme('light'); } },
            { value: this.themeMode === 'dark' ? '深色（当前）' : '深色', action: () => { this.changeTheme('dark'); } }
          ])
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.doc_plaintext_fill_1')).fontSize(22).fontColor([this.colors().secondaryText])
        }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('连接日志')
          .bindTips('连接日志').onClick(() => this.readLogs())
      }.width('100%')
      Row({ space: 8 }) {
        Row() {}.width(8).height(8).borderRadius(4)
          .backgroundColor(this.phase === 'connected' ? this.colors().accent : this.colors().inactive)
        Text(this.phase === 'connected' ? 'VPN 已启动' :
          (this.phase === 'connecting' ? '正在连接' : (this.phase === 'failed' ? '连接失败' : '未连接')))
          .fontSize(14).fontColor(this.colors().secondaryText)
        if (this.busy || this.phase === 'connecting') {
          LoadingProgress().width(20).height(20).color(this.colors().accent)
        }
        Blank()
        Text('VPN').fontSize(12).fontWeight(FontWeight.Bold).fontColor(this.colors().mutedText)
      }.width('100%').margin({ top: 24, bottom: 24 })
      Divider().color(this.colors().border)
      Row() {
        Text('服务器').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
        Text(`${this.servers.length}`).fontSize(13).fontColor(this.colors().mutedText).margin({ left: 8 })
        Blank()
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.plus')).fontSize(23).fontColor([this.colors().accent])
        }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('新建服务器')
          .bindTips('新建服务器').enabled(this.canManage()).onClick(() => this.openEditor())
      }.width('100%').margin({ top: 16, bottom: 8 })
      if (!this.servers.length) {
        Column({ space: 16 }) {
          SymbolGlyph($r('sys.symbol.network_acceleration')).fontSize(44).fontColor([this.colors().inactive])
          Text(this.ready ? '暂无服务器' : '正在读取配置').fontSize(16).fontColor(this.colors().secondaryText)
          if (this.ready) {
            Button('新建服务器', { type: ButtonType.Normal }).height(44).borderRadius(6)
              .backgroundColor(this.colors().accent).fontColor(this.colors().onAccent)
              .enabled(this.canManage()).onClick(() => this.openEditor())
          }
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.servers, (server: ServerProfile) => {
            ListItem() { this.serverRow(server) }
          }, (server: ServerProfile) => server.id)
        }.width('100%').layoutWeight(1)
      }
      if (this.error) {
        Text(this.error).fontSize(13).fontColor(this.colors().danger).width('100%').margin({ top: 12 })
      }
      Column({ space: 12 }) {
        Text(this.selected()?.name ?? '未选择服务器').fontSize(14).fontColor(this.colors().secondaryText)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Button(this.active() ? (this.phase === 'connected' ? '断开连接' : '取消连接') : '连接', { type: ButtonType.Normal })
          .width('100%').height(52).borderRadius(6).fontSize(17).fontWeight(FontWeight.Medium)
          .backgroundColor(this.active() ? this.colors().disconnect : this.colors().accent).fontColor(this.colors().onAccent)
          .enabled(!this.busy && !this.saving && (this.active() || (this.ready && this.selected() !== undefined)))
          .onClick(() => this.toggle())
      }.width('100%').padding({ top: 20 }).margin({ top: 12 })
    }.width('100%').height('100%')
  }

  build() {
    Column() {
      Column() {
        if (this.editing) {
          this.editor()
        } else if (this.showLogs) {
          this.logPage()
        } else {
          this.home()
        }
      }.width('100%').height('100%').constraintSize({ maxWidth: 720 })
        .padding({ left: 24, right: 24, top: 20, bottom: 20 })
    }.width('100%').height('100%').backgroundColor(this.colors().background)
  }
}
