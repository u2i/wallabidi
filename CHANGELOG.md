# Changelog

## [0.31.0](https://github.com/u2i/wallabidi/compare/v0.30.12...v0.31.0) (2026-03-18)


### ⚠ BREAKING CHANGES

* rename project to Wallabidi
* remove Selenium driver and legacy HTTP protocol

### Features

* add BiDi-powered DX features ([2f7fa8e](https://github.com/u2i/wallabidi/commit/2f7fa8e46c5d1370e54778749d71041ed79cf746))
* add WebDriver BiDi protocol support for Chrome driver ([124f438](https://github.com/u2i/wallabidi/commit/124f43883d9c18162a773746c895f7090e05e400))
* auto-propagate Mimic stubs in LiveSandbox, fix optional deps ([bb96ea0](https://github.com/u2i/wallabidi/commit/bb96ea0e2a4d4519442a6f2b43a7d53cdc875ef5))
* auto-start Chrome via Docker when chromedriver not found ([6069fc0](https://github.com/u2i/wallabidi/commit/6069fc02cae1189b2fdf8534395cb67ea4643de6))
* automatic Cachex checkout in Feature setup ([a3df493](https://github.com/u2i/wallabidi/commit/a3df493c2fa0aa33f752881c3a832a986d4373a7))
* Cachex.Sandbox integration — transparent cache isolation ([f3c1bd7](https://github.com/u2i/wallabidi/commit/f3c1bd7f606eebfbaebcee13a1035e425eea1218))
* CachexSandbox pool for test isolation ([0f3e42b](https://github.com/u2i/wallabidi/commit/0f3e42b49f5f652571a8271aab5f57b8aae98acd))
* Docker networking — Chrome in container reaches host test server ([494a422](https://github.com/u2i/wallabidi/commit/494a4229296353ec4c912ea5d1311862aa9b9e72))
* launch Chrome directly — bypass chromedriver entirely ([2509bb1](https://github.com/u2i/wallabidi/commit/2509bb119fe9b43207ad2ce340d8045d3efecdc0))
* make settle LiveView-aware ([6c8ee28](https://github.com/u2i/wallabidi/commit/6c8ee286f32ae2e260ebeb310905dee8a9264b9e))
* MockSandbox plug — propagate Mimic/Mox on HTTP requests too ([de98064](https://github.com/u2i/wallabidi/commit/de98064274bc2cbeee4089f672ac9b2a5043fbdc))
* Mox support — auto-propagate stubs to LiveView processes ([3c2c42b](https://github.com/u2i/wallabidi/commit/3c2c42be2389166974b87c64e192bb1e47baff6c))
* pure BiDi — eliminate all WebdriverClient fallbacks ([b9aa730](https://github.com/u2i/wallabidi/commit/b9aa730679604533b95e22c7d82f243d6b6e636a))
* remove Selenium driver and legacy HTTP protocol ([ab70de9](https://github.com/u2i/wallabidi/commit/ab70de9cb09e39198b14ee63c15f1cdecb445740))
* rename project to Wallabidi ([d23fcc4](https://github.com/u2i/wallabidi/commit/d23fcc4f448f38a4cc3c744ce01949fd321698b0))
* sandbox integration tests pass — all 5 scenarios working ([142c4b0](https://github.com/u2i/wallabidi/commit/142c4b0d741abf4abd80fa02b94de272ad01be43))
* SandboxHelper for Cachex and spawn_link workers ([17495d4](https://github.com/u2i/wallabidi/commit/17495d435510e939f8c1370aa5bfc3295b0ca589))
* support remote ChromeDriver (e.g. Docker container) ([4ad30b4](https://github.com/u2i/wallabidi/commit/4ad30b4474252b48ba8b518d574251139adb81dd))
* use chromedriver with BiDi — inject webSocketUrl capability ([4d7d476](https://github.com/u2i/wallabidi/commit/4d7d47677500aabb3d3e7e048c54b39573f7c054))
* Wallabidi.Sandbox plug and Wallabidi.LiveSandbox on_mount hook ([28878ad](https://github.com/u2i/wallabidi/commit/28878ade758c7bd8db32ae3aba644fceb0592125))


### Bug Fixes

* attribute property access, displayed visibility, dialog subscription, object keys ([e6d92a5](https://github.com/u2i/wallabidi/commit/e6d92a503d30eb997b01d4fc53b9c011b4784738))
* attribute reads DOM property, defensive session cleanup ([866a365](https://github.com/u2i/wallabidi/commit/866a3655bd03950520d1e0bf7ebcf184be1951e8))
* Cachex $callers fix is in 4.1+, not 4.0+ ([60c8dd9](https://github.com/u2i/wallabidi/commit/60c8dd99a4f784cadb24c6a0e6331c024677b194))
* CI and test fixes for Selenium removal ([a6cf794](https://github.com/u2i/wallabidi/commit/a6cf794c07f0e8ee822404660df75924af104482))
* click fallback for all non-stale errors ([d017c6e](https://github.com/u2i/wallabidi/commit/d017c6e9aad61a31bfd26580033107571f27897c))
* defensive end_session — catch already-dead WebSocket ([20ac190](https://github.com/u2i/wallabidi/commit/20ac19029147e051c52b18666d44392196327c88))
* dialyzer — pattern match status 101 before WebSocket.new ([c91df0f](https://github.com/u2i/wallabidi/commit/c91df0f0864658fa6457d268a3eebd00737d5b36))
* don't call mint_request inside GenServer callbacks ([51526cc](https://github.com/u2i/wallabidi/commit/51526cc570dfdc935ee958e9bf019a71f3995c28))
* frame switching, file inputs, capabilities tests, version messages ([c2cc876](https://github.com/u2i/wallabidi/commit/c2cc8769da8d8d36f4469f431e65d00fba8dd5aa))
* handle missing goog:chromeOptions in capability manipulation ([a3e235f](https://github.com/u2i/wallabidi/commit/a3e235ff71a884b7c17f8daf7d0e48dedbf08096))
* JS error/log tests — allow async BiDi events to arrive ([4791fe0](https://github.com/u2i/wallabidi/commit/4791fe0cc6e2cc5354505f53a31f3ead97dadc46))
* last 2 test failures — skip invisible click, settle for log timing ([17163f9](https://github.com/u2i/wallabidi/commit/17163f9fa058a739a6336eebd7fa8f33ed7afc66))
* last 3 integration test failures ([04f0672](https://github.com/u2i/wallabidi/commit/04f0672bac6ebae4db8cf2d23e8b1db916ed7c9e))
* make BiDi opportunistic — don't modify capabilities ([45d42a6](https://github.com/u2i/wallabidi/commit/45d42a60df83f4884723e9c7ca2a5c70d39d9aba))
* make wait_for_network_idle work with persistent connections ([27578a7](https://github.com/u2i/wallabidi/commit/27578a7aa3bf5127a700abb69e0e50d4bebbc203))
* only hide absolutely/fixed positioned off-screen elements ([0eab11b](https://github.com/u2i/wallabidi/commit/0eab11b1297c380afaca7f19a217de0f69d8c9b3))
* parse session ID from W3C response format ([0766a98](https://github.com/u2i/wallabidi/commit/0766a98faf4fed1382c39fd6c4ed22ce7f65d9a5))
* queue WebSocket commands until handshake completes ([e454f2f](https://github.com/u2i/wallabidi/commit/e454f2fe8c9e491d99ba10164b226c5625071003))
* remote chromedriver improvements ([ac8ee0a](https://github.com/u2i/wallabidi/commit/ac8ee0ab6e8f5998cc8fe2635e92e2a5acd8c7ed))
* remove worktree from git, add .claude to gitignore ([0b7a3f5](https://github.com/u2i/wallabidi/commit/0b7a3f5c27e4e2d98b3c996cf8e01e3deec6dd8c))
* replace all remaining wallaby references with wallabidi ([d503255](https://github.com/u2i/wallabidi/commit/d5032558d0c497ce8515204110d4b5bf5e030ff9))
* resolve credo issues — reduce nesting, fix alias order ([a044fe9](https://github.com/u2i/wallabidi/commit/a044fe9e62ab385f57cfbd0e8dd67f3e762ce67a))
* resolve dialyzer errors ([6e115b1](https://github.com/u2i/wallabidi/commit/6e115b18c92da0b9f852b1de3dbb429a6eab6dc2))
* resolve remaining 23 integration test failures ([654f503](https://github.com/u2i/wallabidi/commit/654f5031c8b185a2d58744abf9d6864678f0611e))
* restore chromedriver validation and filter mapper log noise ([bbf76e2](https://github.com/u2i/wallabidi/commit/bbf76e266565b599c434a4cb2bd3003d787d239b))
* use atom key for goog:chromeOptions Access ([8119414](https://github.com/u2i/wallabidi/commit/811941463f6e0822046d09f7949cd55700e4d3bb))
* use bare chromedriver image, skip tests when no local chromedriver ([8b16ba1](https://github.com/u2i/wallabidi/commit/8b16ba1189beb223cb53c19de44216de66582acd))
* use compile_env guard — zero production overhead ([c881dac](https://github.com/u2i/wallabidi/commit/c881dac986769e87cf44e70dd9bed83e55bd013a))
* use JS .click() instead of pointer actions for element clicks ([96eceed](https://github.com/u2i/wallabidi/commit/96eceedd55a5f8e8d245b6bab7fc5cbdd2bb747c))
* use sharedReference format for BiDi script arguments ([2b7fbf4](https://github.com/u2i/wallabidi/commit/2b7fbf465550d48808198e4b4922aa7daab5e1bb))
* use W3C capabilities format for session creation ([37970c0](https://github.com/u2i/wallabidi/commit/37970c02f07a303bea774f97233abef49c73a31d))
* use W3C capability keys throughout ([c6c5fab](https://github.com/u2i/wallabidi/commit/c6c5fabaa6d37fa9329e4027b7fc6053cf438150))


### Performance Improvements

* single chromedriver process for all tests ([4359e45](https://github.com/u2i/wallabidi/commit/4359e452306ad121c52cb1b552d2aa73d0196670))

## [0.30.12](https://github.com/elixir-wallaby/wallaby/compare/v0.30.11...v0.30.12) (2026-01-09)


### Bug Fixes

* flush a DOWN message if one was present ([#832](https://github.com/elixir-wallaby/wallaby/issues/832)) ([63d64de](https://github.com/elixir-wallaby/wallaby/commit/63d64dec492d06f4b609c67bfef41deac161b8a5))

## [0.30.11](https://github.com/elixir-wallaby/wallaby/compare/v0.30.10...v0.30.11) (2025-10-29)


### Bug Fixes

* removed elixir 1.19 warnings ([#823](https://github.com/elixir-wallaby/wallaby/issues/823)) ([f64b943](https://github.com/elixir-wallaby/wallaby/commit/f64b943aca168ddf5869081201a5993384a66d61))

## v0.30.10

- only automatically start sessions for `feature` test macros and not every test in a file by @s3cur3 in https://github.com/elixir-wallaby/wallaby/pull/795

## v0.30.9

- fix unhandled alerts by @s3cur3 in https://github.com/elixir-wallaby/wallaby/pull/779

## v0.30.8

- fix malformed JSON from chromedriver by @s3cur3 in https://github.com/elixir-wallaby/wallaby/pull/778

## v0.30.7

- refactor to map_intersperse by @bradhanks in https://github.com/elixir-wallaby/wallaby/pull/758
- Fix Wallaby.Element.size/1 spec by @NikitaNaumenko in https://github.com/elixir-wallaby/wallaby/pull/759
- Update README to Avoid Elixir Warning by @stratigos in https://github.com/elixir-wallaby/wallaby/pull/762
- Update README: Local Sandbox File Location by @stratigos in https://github.com/elixir-wallaby/wallaby/pull/766
- Update chrome.ex by @RicoTrevisan in https://github.com/elixir-wallaby/wallaby/pull/768
- Make Query.text/2 docs also point to assert_text/{2,3} by @s3cur3 in https://github.com/elixir-wallaby/wallaby/pull/770
- Update README: Separate Phoenix setup from Ecto by @Corkle in https://github.com/elixir-wallaby/wallaby/pull/772
- Address deprecation; prefer ExUnit.Case.register_test/6 by @vanderhoop in https://github.com/elixir-wallaby/wallaby/pull/776
- Fix newer invalid selector error from chromedriver by @mhanberg in 4f82ca82a6c417d298663ac4a996d49e1150d6f2

## v0.30.6

- fix: concurrent tests when using custom capabilities (#744)

## v0.30.5

- Workaround for chromedriver 115 regression (#740)

## v0.30.4

- Set headless and binary chromedriver opts from the `@sessions` attribute in feature tests (#736)

## v0.30.3

- Better support Chromedriver tests on machines with tons of cores

## v0.30.2

- Surface 'text' condition in css query error message (#714)
- Allow 2.0 in httpoison in version constraint (#725)
- Allow setting of optional cookie attributes (#711)

## v0.30.1 (2022-07-16)

### Fixes

- fix(chromedriver): Account for Chromium when doing the version matching (#698)

## v0.30.0 (2022-07-14)

### Breaking

- Now only supports Elixir v1.12 and higher. Please open an issue if this is too restrictive. This was done to allow us to vendor `PartitionSupervisor`, which uses functions that were introduced in v1.12, so vendoring only gets us that far.

### Fixes

- Handle errors related to Wallaby.Element more consistently #632
- Fix `refute_has` when passed a query with an invalid selector #639
- Fix ambiguity between imported Browser.tap/2 and Kernel.tap/2 #686
- Fix `remote_url` config option for selenium driver #582
- Specifying `at` now removes the default `count` of 1 #641
- Various documentation fixes/improvements
- Start a ChromeDriver for every scheduler #692
  - This may fix a long standing issue #365

## v0.29.1 (2021-09-22)

- Docs improvements #629

## v0.29.0 (2021-09-14)

- `has_css?/3` returns a boolean instead of raising. (#624)
- Updates `web_driver_client` to v0.2.0 (#625)

## v0.28.1 (2021-07-31)

- Fix async tests when using selenium and the default capabilities.
- Fixes the DependencyError message in chrome.ex (#581)

## v0.28.0 (2020-12-8)

### Breaking

- `Browser.assert_text/2` and `Browser.assert_text/3` now return the parent instead of `true` when the text was found.

### Fixes

- File uploads when using local and remote selenium servers.

### Improvements

- Added support for touch events
 - `Wallaby.Browser.touch_down/3`
 - `Wallaby.Browser.touch_down/4`
 - `Wallaby.Browser.touch_up/1`
 - `Wallaby.Browser.tap/2`
 - `Wallaby.Browser.touch_move/3`
 - `Wallaby.Browser.touch_scroll/4`
 - `Wallaby.Element.touch_down/3`
 - `Wallaby.Element.touch_scroll/3`

- Added support for getting Element size and location
  - `Wallaby.Element.size/1`
  - `Wallaby.Element.location/1`

## 0.27.0 (2020-12-4)

### Breaking

- Increases minimum Elixir version to 1.8

### Fixes

- Correctly remove stopped sessions from the internal store. [#558](https://github.com/elixir-wallaby/wallaby/pull/558)
- Ensures all sessions are closed after the test suite is over.
- Tests won't crash when side effects fail when calling the inspect protocol on an Element

## 0.26.2 (2020-06-19)

### Fixes

- Improve `Query.t()` specification to fix dialyzer warnings. Fixes [#542](https://github.com/elixir-wallaby/wallaby/issues/542)

## 0.26.1 (2020-06-17)

### Fixes

- Change Wallaby.Browser.sync_result from `@opaque` to `@type` Fixes [#540](https://github.com/elixir-wallaby/wallaby/issues/540)

## 0.26.0 (2020-06-15)

### Remove `Wallaby.Phantom`

The PhantomJS driver was deprecated in v0.25.0 because it is no longer maintained and does not implement many modern browser features.

Users are encouraged to switch to the `Wallaby.Chrome` driver, which is now the default. `Wallaby.Chrome` requires installing `chromedriver` as well as Google Chrome, both of which now come pre-installed on many CI platforms.

## 0.25.1 (2020-06-09)

### Fixes

- Add `ecto_sql` and `phoenix_ecto`

## 0.25.0 (2020-05-27)

### Deprecations

- Deprecated `Wallaby.Phantom`, please switch to `Wallaby.Chrome` or `Wallaby.Selenium`

### Breaking

- `Wallaby.Experimental.Chrome` renamed to `Wallaby.Chrome`.
- `Wallaby.Experimental.Selenium` renamed to `Wallaby.Selenium`.
- `Wallaby.Chrome` is now the default driver.

## 0.24.1 (2020-05-21)

- Compatibility fix for ChromeDriver version >= 83. Fixes [#533](https://github.com/elixir-wallaby/wallaby/issues/533)

## 0.24.0 (2020-04-15)

### Improvements

- Enables the ability to set capabilities by passing them as an option and using application configuration.
- Implements default capabilities for Selenium.
- Implements the `Wallaby.Feature` module.

#### Breaking

- Moves configuration options for using chrome headlessly, the chrome binary, and the chromedriver binary to the `:chromedriver` key in the `:wallaby` application config.
- Automatic screenshots will now only occur inside the `feature` macro.
- Removed `:create_session_fn` option from `Wallaby.Experimental.Selenium`
- Removed `:end_session_fn` option from `Wallaby.Experimental.Selenium`
- Increases the minimum Elixir version to v1.7.
- Increases the minimum Erlang version to v21.

## 0.23.0 (2019-08-14)

### Improvements

- Add ability to configure the path to the ChromeDriver executable
- Enable screenshot support for Selenium driver
- Enable `accept_alert/2`, `dismiss_alert/2`, `accept_confirm/2`, `dismiss_confirm/2`, `accept_prompt/2`, `dismiss_prompt/2` for Selenium driver
- Add `:log` option to `take_screenshot`, this is set to `true` when taking screenshots on failure
- Introduce window/tab switching support: `Browser.window_handle/1`, `Browser.window_handles/1`, `Browser.focus_window/2` and `Browser.close_window/1`
- Introduce window placement support: `Browser.window_position/1`, `Browser.move_window/3` and `Browser.maximize_window/1`
- Introduce frame switching support: `Browser.focus_frame/2`, `Browser.focus_parent_frame/1`, `Browser.focus_default_frame/1`
- Introduce async script support: `Browser.execute_script_async/2`, `Browser.execute_script_async/3`, and `Browser.execute_script_async/4`
- Introduce mouse events support: `Browser.hover/2`, `Browser.move_mouse_by/3`, `Browser.double_click/1`, `Browser.button_down/2`, `Browser.button_up/2`, and a version of `Browser.click/2` that clicks in current mouse position.

### Bugfixes

- LogStore now wraps logs in a list before attempting to pass them to List functions. This was causing Wallaby to crash and would mask actual test errors.

## 0.22.0 (2019-02-26)

### Improvements

- Add `Query.data` to find by data attributes
- Add selected conditions to query
- Add functions for query options
- Add `visible: any` option to query
- Handle Safari and Edge stale reference errors

### Bugfixes

- allow newlines in chrome logs
- Allow other versions of chromedriver
- Increase the session store genserver timeout

## 0.21.0 (2018-11-19)

### Breaking changes

- Removed `accept_dialogs` and `dismiss_dialogs`.

### Improvements

- Improved readability of `file_test` failures
- Allow users to specify the path to the chrome binary
- Add Query.value and Query.attribute
- Adds jitter to all http calls
- Returns better error messages from obscured element responses
- Option to configure default window size
- Pretty printing element html

### Bugfixes

- Chrome takes screenshots correctly if elements are passed to `take_screenshot`.
- Chrome no longer spits out errors constantly.
- Find elements that contain single quotes

## 0.20.0 (2018-04-11)

### Breaking changes

- Normalized all exception names
- Removed `set_window_size/3`

### Bugfixes

- Fixed issues with zombie phantom processes (#338)

## 0.19.2 (2017-10-28)

### Features

- Capture JavaScript logs in chrome
- Queries now take an optional `at:` argument with which you can specify which one of multiple matches you want returned

### Bugfixes

- relax httpoison dependency for easier upgrading and not locking you down
- Prevent failing if phantom jsn't installed globally
- Fix issue with zombie phantomjs processes (#224)
- Fix issue where temporary folders for phantomjs processes aren't deleted

## 0.19.1 (2017-08-13)

### Bugfixes

- Publish new release with an updated version of hex to fix file permissions.

## 0.19.0 (2017-08-08)

### Features

- Handle alerts in chromedriver - thanks @florinpatrascu

### Bugfixes

- Return the correct error message for text queries.

## 0.18.1 (2017-07-19)

### Bugfixes

- Pass correct BEAM Metadata to chromedriver to support db_connection
- Close all sessions when their parent process dies.

## 0.18.0 (2017-07-17)

### Features

- Support for chromedriver

### Bugfixes

- Capture invalid state errors

## 0.17.0 (2017-05-17)

This release removes all methods declared as _deprecated_ in the 0.16 release, experimental Selenium support and much more! If you are looking to upgrade from an earlier release, it is recommended to first go to 0.16.x.
Other goodies include improved test helpers, a cookies API and handling for JS-dialogues.

### Breaking Changes

- Removed deprecated version of `fill_in`
- Removed deprecated `check`
- Removed deprecated `set_window_size`
- Removed deprecated `send_text`
- Removed deprecated versions of `click`
- Removed deprecated `checked?`
- Removed deprecated `get_current_url`
- Removed deprecated versions of `visible?`
- Removed deprecated versions of `all`
- Removed deprecated versions of `attach_file`
- Removed deprecated versions of `clear`
- Removed deprecated `attr`
- Removed deprecated versions of `find`
- Removed deprecated versions of `text`
- Removed deprecated `click_link`
- Removed deprecated `click_button`
- Removed deprecated `choose`

### Features

- New cookie API with `cookies/1` and `set_cookie/3`
- New assert macros `assert_has/2` and `refute_has/2`
- execute_script now returns the session again and is pipable, there is an optional callback if you need access to the return value - thanks @krankin
- Phantom server is now compatible with escripts - thanks @aaronrenner
- Ability to handle JavaScript dialogs via `accept_dialogs/1`, `dismiss_dialogs/1`, plus methods for alerts, confirms and prompts - thanks @padde
- Ability to pass options for driver interaction down to the underlying hackney library through `config :wallaby, hackney_options: [your: "option"]` - thanks @aaronrenner
- Added `check_log` option to `execute_script` - thanks @aaronrenner
- Experimental support for selnium 2 and selenium 3 web drivers has been added, use at your own risk ;)
- Updated hackney and httpoison dependencies - thanks @aaronrenner
- Removed documentation for modules that aren't intended for external use - thanks @aaronrenner
- set_value now works with text fields, checkboxes, radio buttons, and
  options. - thanks @graeme-defty

### Bugfixes

- Fix spawning of phantomjs when project path contains spaces - thanks @schnittchen
- Fixed a couple of dialyzer warnings - thanks @aaronrenner
- Fixed incorrect malformed label warning when it was really a mismatch between expected elements found

## <= 0.16.1

Changelogs for these versions can be found under [releases](https://github.com/keathley/wallaby/releases)
