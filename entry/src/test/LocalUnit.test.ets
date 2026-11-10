import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { validateServer } from '../main/ets/model/SocksConfig';
import { migrateServer, removeServer, ServerProfile, ServerSettings, validateProfile } from '../main/ets/model/ServerStore';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { normalizeTheme, resolveTheme } from '../main/ets/model/ThemeStore';

export default function localUnitTest() {
  describe('localUnitTest', () => {
    it('migrateLegacyServer', 0, () => {
      const settings = migrateServer({ host: '192.168.3.13', port: 1080 });
      expect(settings.servers.length).assertEqual(1);
      expect(settings.servers[0].host).assertEqual('192.168.3.13');
      expect(settings.servers[0].port).assertEqual(1080);
      expect(settings.servers[0].name).assertEqual('默认服务器');
      expect(settings.selectedId).assertEqual(settings.servers[0].id);
      expect(migrateServer({ host: '', port: 1080 }).servers.length).assertEqual(0);
    });
    it('deleteServerPreservesValidSelection', 0, () => {
      const first: ServerProfile = { id: 'first', name: 'First', host: '192.0.2.1', port: 1080 };
      const second: ServerProfile = { id: 'second', name: 'Second', host: '192.0.2.2', port: 1080 };
      const settings: ServerSettings = { servers: [first, second], selectedId: first.id };
      expect(removeServer(settings, second.id).selectedId).assertEqual(first.id);
      const remaining = removeServer(settings, first.id);
      expect(remaining.selectedId).assertEqual(second.id);
      const empty = removeServer(remaining, second.id);
      expect(empty.servers.length).assertEqual(0);
      expect(empty.selectedId).assertEqual('');
      expect(settings.servers.length).assertEqual(2);
    });
    it('validateNamedServer', 0, () => {
      expect(validateProfile({ id: 'test', name: 'Home', host: '192.0.2.1', port: 1080 })).assertEqual('');
      expect(validateProfile({ id: 'test', name: ' ', host: '192.0.2.1', port: 1080 }).length > 0).assertTrue();
      expect(validateProfile({ id: 'test', name: 'Home', host: '::1', port: 1080 }).length > 0).assertTrue();
      expect(validateProfile({ id: 'test', name: 'Home', host: '192.0.2.1', port: 0 }).length > 0).assertTrue();
    });
    it('normalizeSavedTheme', 0, () => {
      expect(normalizeTheme('dark')).assertEqual('dark');
      expect(normalizeTheme('light')).assertEqual('light');
      expect(normalizeTheme('system')).assertEqual('system');
      expect(normalizeTheme('')).assertEqual('system');
      expect(normalizeTheme('invalid')).assertEqual('system');
    });
    it('resolveSystemThemeAndManualOverride', 0, () => {
      const light = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      const dark = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      expect(resolveTheme('system', light)).assertEqual('light');
      expect(resolveTheme('system', dark)).assertEqual('dark');
      expect(resolveTheme('system', undefined)).assertEqual('light');
      expect(resolveTheme('light', dark)).assertEqual('light');
      expect(resolveTheme('dark', light)).assertEqual('dark');
    });
    it('rejectNonAsciiServerAddress', 0, () => {
      expect(validateServer('192.168.3.13', '1080')).assertEqual('');
      expect(validateServer('192\u00b7168.3.13', '1080').length > 0).assertTrue();
      expect(validateServer('192\uff0e168.3.13', '1080').length > 0).assertTrue();
    });
    it('rejectUnsupportedAddressFamily', 0, () => {
      expect(validateServer('proxy.example.com', '1080')).assertEqual('');
      expect(validateServer('::1', '1080').length > 0).assertTrue();
      expect(validateServer('[2001:db8::1]', '1080').length > 0).assertTrue();
      expect(validateServer('::ffff:192.168.3.13', '1080').length > 0).assertTrue();
    });
    // Defines a test suite. Two parameters are supported: test suite name and test suite function.
    beforeAll(() => {
      // Presets an action, which is performed only once before all test cases of the test suite start.
      // This API supports only one parameter: preset action function.
    });
    beforeEach(() => {
      // Presets an action, which is performed before each unit test case starts.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: preset action function.
    });
    afterEach(() => {
      // Presets a clear action, which is performed after each unit test case ends.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: clear action function.
    });
    afterAll(() => {
      // Presets a clear action, which is performed after all test cases of the test suite end.
      // This API supports only one parameter: clear action function.
    });
    it('assertContain', 0, () => {
      // Defines a test case. This API supports three parameters: test case name, filter parameter, and test case function.
      let a = 'abc';
      let b = 'b';
      // Defines a variety of assertion methods, which are used to declare expected boolean conditions.
      expect(a).assertContain(b);
      expect(a).assertEqual(a);
    });
  });
}