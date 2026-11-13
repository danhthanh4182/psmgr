/* PSManager landing page behaviour: i18n, theme, install tabs, copy, menu, reveal. */
'use strict';

(function () {
  var LANG_KEY = 'psmgr-site-lang';
  var THEME_KEY = 'psmgr-site-theme';
  var THEME_COLORS = { dark: '#07101F', light: '#F5F8FD' };

  var I18N = {
    en: {
      skip: 'Skip to content',
      brand_home: 'PSManager home',
      nav_label: 'Main navigation',
      nav_features: 'Features',
      nav_interfaces: 'Interfaces',
      nav_install: 'Install',
      nav_faq: 'FAQ',
      nav_github: 'GitHub',
      lang_toggle_label: 'Switch to Vietnamese',
      theme_toggle_label: 'Toggle light and dark theme',
      menu_toggle_label: 'Toggle navigation menu',

      hero_eyebrow: 'Windows 10/11 · PowerShell 5.1 + 7.4+',
      hero_title: 'One command. PowerShell 7 everywhere.',
      hero_lead: 'Set PS7 as the default shell, keep profiles in sync, and manage backups, updates and diagnostics from a CLI, TUI or native desktop app.',
      hero_cta_primary: 'Install PSManager',
      hero_cta_secondary: 'Explore the code',
      hero_terminal_label: 'PowerShell 7',
      hero_terminal_note: 'Points new terminals at PS7 and keeps every PSManager action aimed at the same shell.',
      copy: 'Copy',
      copy_label: 'Copy command',
      copy_ok: 'Copied',
      copy_fail: 'Copy failed',
      hero_shot_alt: 'PSManager desktop app showing the Overview page with PowerShell versions, the default shell and quick actions',

      compat_label: 'Runs on',
      compat_win: 'Windows 10/11',
      compat_ps5: 'PowerShell 5.1',
      compat_ps7: 'PowerShell 7.4+',
      compat_wt: 'Windows Terminal',
      compat_winget: 'winget',
      compat_msstore: 'Microsoft Store',
      compat_github: 'GitHub Releases',

      interfaces_title: 'Three interfaces, one engine',
      interfaces_lead: 'The same PowerShell core and the same configuration, whichever way you drive it.',
      interfaces_cli_title: 'CLI',
      interfaces_cli_desc: 'Short commands for scripts and CI: status, defaults, sync, backups and updates.',
      interfaces_cli_item_1: 'Environment, default shell and update status',
      interfaces_cli_item_2: 'Make PS7 or PS5.1 the default shell',
      interfaces_cli_item_3: 'Link profiles and audit the machine',
      interfaces_cli_item_4: 'Check for and install PSManager updates',
      interfaces_tui_title: 'TUI',
      interfaces_tui_desc: 'A full-screen terminal app with keyboard navigation, search and a help overlay.',
      interfaces_tui_key_move: 'Move between actions',
      interfaces_tui_key_search: 'Search actions',
      interfaces_tui_key_help: 'Open the help overlay',
      interfaces_tui_key_gui: 'Launch the desktop app',
      interfaces_gui_title: 'GUI',
      interfaces_gui_desc: 'A native WPF app with six pages: Overview, Update, Backup, Health, Profile and Help.',
      interfaces_gui_alt: 'PSManager desktop app Overview page',
      card_cta_install: 'Install',

      features_title: 'Everything in one control center',
      features_lead: 'PSManager turns the things you have to remember into buttons you can press.',
      feature_default_title: 'One-click PS7 default',
      feature_default_desc: 'Switch the default shell between PowerShell 7 and Windows PowerShell 5.1, with Windows Terminal wired up.',
      feature_sources_title: 'Multi-source updater',
      feature_sources_desc: 'Install and upgrade PowerShell from winget, Microsoft Store or GitHub, on stable, preview or lts channels.',
      feature_sync_title: 'Profile sync',
      feature_sync_desc: 'Link dotfiles, provision packages and let PS5.1 and PS7 share one set of profiles.',
      feature_backup_title: 'Encrypted backups',
      feature_backup_desc: 'Pack profiles and configuration into a ZIP, optionally encrypted, and restore with one command.',
      feature_doctor_title: 'Doctor audit',
      feature_doctor_desc: 'psmgr doctor and audit-profile catch PATH problems, broken profiles and missing installs, with an optional fix.',
      feature_updates_title: 'Update notifications',
      feature_updates_desc: 'Cached release checks, an unread badge, and a SHA-256 verified installer before anything runs.',
      feature_help_title: 'Help center',
      feature_help_desc: 'One command catalog behind psmgr help, the TUI overlay and the Help page in the desktop app.',
      feature_lang_title: 'Bilingual UI',
      feature_lang_desc: 'English, Vietnamese and ASCII-safe Vietnamese across the CLI, the TUI and the GUI.',

      updates_title: 'Updates without surprises',
      updates_lead: 'PSManager checks for its own releases but never installs one behind your back. You see the notice, you make the call.',
      updates_point_cache_title: 'Six-hour cached checks',
      updates_point_cache_desc: 'Results land in updates.json and are reused for six hours, so startup never waits on the network.',
      updates_point_badge_title: 'Unread badge and native toasts',
      updates_point_badge_desc: 'A bell badge, an in-app notification center, and a native Windows toast when a release appears.',
      updates_point_sha_title: 'SHA-256 verified installer',
      updates_point_sha_desc: 'The installer is downloaded next to SHA256SUMS.txt and checked before it runs. No unverified path exists.',
      updates_point_confirm_title: 'You confirm every install',
      updates_point_confirm_desc: 'Nothing upgrades in the background. PSManager installs only after you click, or type y.',
      updates_shot_alt: 'PSManager Update page listing PowerShell versions and the package source',

      install_title: 'Install PSManager',
      install_lead: 'Pick whichever fits. All three routes ship the same installer and the same release.',
      install_tabs_label: 'Install methods',
      install_tab_winget: 'winget',
      install_tab_ps7: 'PowerShell 7',
      install_tab_ps51: 'Windows PowerShell 5.1',
      install_winget_caption: 'Installs from the winget community repository. Run psmgr afterwards to open the terminal UI.',
      install_ps7_caption: 'Run it inside PowerShell 7. The script checks the environment before downloading anything.',
      install_ps51_caption: 'For the inbox Windows PowerShell 5.1 that ships with Windows 10 and 11.',
      install_requirements: 'Windows 10 or 11 with PowerShell 5.1 or later. No admin rights needed for a per-user install.',
      install_note_title: 'Private preview',
      install_note_body: 'Until the repository is public, authenticate first so the installer can reach the release:',
      install_note_alt: 'Or set PSMGR_GITHUB_TOKEN in your environment before running the installer.',

      faq_title: 'Frequently asked questions',
      faq_q1: 'Why does Windows SmartScreen warn me?',
      faq_a1: 'The installer is not code-signed yet, so SmartScreen may ask for confirmation. Choose More info, then Run anyway, after checking the SHA-256 digest against SHA256SUMS.txt in the release.',
      faq_q2: 'Can I install from a private repository?',
      faq_a2: 'Yes, if you have access. Run gh auth login or set PSMGR_GITHUB_TOKEN to a token that can read releases, then install again. Setting PSMGR_DISABLE_UPDATE_CHECK=1 turns the release check off entirely.',
      faq_q3: 'Does it run on Windows PowerShell 5.1?',
      faq_a3: 'Yes. Every module runs on Windows PowerShell 5.1 and PowerShell 7.4 or later, including the update check and the notification store.',
      faq_q4: 'How do I uninstall PSManager?',
      faq_a4: 'Use Settings, Apps, Installed apps, or run winget uninstall --id danhthanh4182.PSManager. User state in %LOCALAPPDATA%\\PSManager is kept; delete that folder for a clean removal.',
      faq_q5: 'Where do update notifications come from?',
      faq_a5: 'PSManager reads its own GitHub releases API at most once every six hours. Each check is one request; set PSMGR_DISABLE_UPDATE_CHECK=1 to disable it and PSMGR_DISABLE_TOASTS=1 to silence native toasts.',

      cta_title: 'Ready to make PowerShell 7 the default?',
      cta_lead: 'One command gets you the CLI, the TUI and the desktop app, all sharing one manager.',
      cta_primary: 'Install PSManager',
      cta_secondary: 'Read the docs',

      footer_tagline: 'A PowerShell version manager for Windows, written in PowerShell.',
      footer_product: 'Product',
      footer_resources: 'Resources',
      footer_links_github: 'GitHub',
      footer_links_releases: 'Releases',
      footer_links_issues: 'Issues',
      footer_links_docs: 'Docs',
      footer_links_license: 'MIT License',
      footer_version_label: 'Current version',
      footer_disclaimer: 'Not affiliated with Microsoft. PowerShell is a trademark of Microsoft Corporation.',

      error_title: 'This page does not exist',
      error_lead: 'The link may be out of date, or the page moved. Head back to the PSManager home page.',
      error_back: 'Back to PSManager'
    },
    vi: {
      skip: 'Chuyển tới nội dung',
      brand_home: 'Trang chủ PSManager',
      nav_label: 'Điều hướng chính',
      nav_features: 'Tính năng',
      nav_interfaces: 'Giao diện',
      nav_install: 'Cài đặt',
      nav_faq: 'Hỏi đáp',
      nav_github: 'GitHub',
      lang_toggle_label: 'Chuyển sang tiếng Anh',
      theme_toggle_label: 'Bật tắt giao diện sáng và tối',
      menu_toggle_label: 'Mở hoặc đóng menu điều hướng',

      hero_eyebrow: 'Windows 10/11 · PowerShell 5.1 + 7.4+',
      hero_title: 'Một câu lệnh. PowerShell 7 ở mọi nơi.',
      hero_lead: 'Đặt PS7 làm shell mặc định, đồng bộ profile, quản lý sao lưu, cập nhật và chẩn đoán từ CLI, TUI hay ứng dụng desktop gốc Windows.',
      hero_cta_primary: 'Cài đặt PSManager',
      hero_cta_secondary: 'Xem mã nguồn',
      hero_terminal_label: 'PowerShell 7',
      hero_terminal_note: 'Hướng terminal mới sang PS7 và giữ mọi thao tác của PSManager trên cùng một shell.',
      copy: 'Sao chép',
      copy_label: 'Sao chép câu lệnh',
      copy_ok: 'Đã sao chép',
      copy_fail: 'Sao chép thất bại',
      hero_shot_alt: 'Cửa sổ PSManager ở trang Tổng quan, hiển thị phiên bản PowerShell, shell mặc định và các thao tác nhanh',

      compat_label: 'Chạy trên',
      compat_win: 'Windows 10/11',
      compat_ps5: 'PowerShell 5.1',
      compat_ps7: 'PowerShell 7.4+',
      compat_wt: 'Windows Terminal',
      compat_winget: 'winget',
      compat_msstore: 'Microsoft Store',
      compat_github: 'GitHub Releases',

      interfaces_title: 'Ba giao diện, một bộ máy',
      interfaces_lead: 'Cùng một lõi PowerShell và cùng một cấu hình, dù bạn điều khiển theo cách nào.',
      interfaces_cli_title: 'CLI',
      interfaces_cli_desc: 'Lệnh ngắn gọn cho script và CI: trạng thái, shell mặc định, đồng bộ, sao lưu và cập nhật.',
      interfaces_cli_item_1: 'Môi trường, shell mặc định và trạng thái cập nhật',
      interfaces_cli_item_2: 'Đặt PS7 hoặc PS5.1 làm shell mặc định',
      interfaces_cli_item_3: 'Liên kết profile và kiểm tra hệ thống',
      interfaces_cli_item_4: 'Kiểm tra và cài bản cập nhật PSManager',
      interfaces_tui_title: 'TUI',
      interfaces_tui_desc: 'Ứng dụng terminal toàn màn hình với điều hướng bằng phím, tìm kiếm và lớp phủ trợ giúp.',
      interfaces_tui_key_move: 'Di chuyển giữa các thao tác',
      interfaces_tui_key_search: 'Tìm kiếm thao tác',
      interfaces_tui_key_help: 'Mở lớp phủ trợ giúp',
      interfaces_tui_key_gui: 'Mở ứng dụng desktop',
      interfaces_gui_title: 'GUI',
      interfaces_gui_desc: 'Ứng dụng WPF gốc với sáu trang: Tổng quan, Cập nhật, Sao lưu, Sức khoẻ, Hồ sơ và Trợ giúp.',
      interfaces_gui_alt: 'Trang Tổng quan của PSManager trong ứng dụng desktop',
      card_cta_install: 'Cài đặt',

      features_title: 'Mọi thứ trong một trung tâm điều khiển',
      features_lead: 'PSManager biến những việc bạn phải nhớ thành những nút bấm rõ ràng.',
      feature_default_title: 'Đặt PS7 mặc định một cú nhấp',
      feature_default_desc: 'Chuyển shell mặc định giữa PowerShell 7 và Windows PowerShell 5.1, có cấu hình Windows Terminal đi kèm.',
      feature_sources_title: 'Cập nhật đa nguồn',
      feature_sources_desc: 'Cài và nâng cấp PowerShell từ winget, Microsoft Store hoặc GitHub, theo kênh stable, preview hay lts.',
      feature_sync_title: 'Đồng bộ profile',
      feature_sync_desc: 'Liên kết dotfile, cài gói cần thiết và để PS5.1 với PS7 dùng chung một bộ profile.',
      feature_backup_title: 'Sao lưu có mã hoá',
      feature_backup_desc: 'Đóng gói profile và cấu hình thành tệp ZIP, tuỳ chọn mã hoá, rồi khôi phục bằng một lệnh.',
      feature_doctor_title: 'Chẩn đoán hệ thống',
      feature_doctor_desc: 'psmgr doctor và audit-profile phát hiện lỗi PATH, profile hỏng và phần cài thiếu, kèm tuỳ chọn sửa.',
      feature_updates_title: 'Thông báo cập nhật',
      feature_updates_desc: 'Kiểm tra bản phát hành có bộ nhớ đệm, huy hiệu chưa đọc và bộ cài được xác minh SHA-256 trước khi chạy.',
      feature_help_title: 'Trung tâm trợ giúp',
      feature_help_desc: 'Một danh mục lệnh dùng chung cho psmgr help, lớp phủ TUI và trang Trợ giúp trong ứng dụng.',
      feature_lang_title: 'Giao diện song ngữ',
      feature_lang_desc: 'Tiếng Anh, tiếng Việt và tiếng Việt không dấu, áp dụng cho CLI, TUI và GUI.',

      updates_title: 'Cập nhật không bất ngờ',
      updates_lead: 'PSManager tự kiểm tra bản phát hành của chính nó nhưng không bao giờ cài sau lưng bạn. Bạn thấy thông báo, bạn quyết định.',
      updates_point_cache_title: 'Kiểm tra có bộ nhớ đệm 6 giờ',
      updates_point_cache_desc: 'Kết quả được lưu vào updates.json và dùng lại trong sáu giờ, nên lúc khởi động không phải chờ mạng.',
      updates_point_badge_title: 'Huy hiệu chưa đọc và thông báo hệ thống',
      updates_point_badge_desc: 'Huy hiệu trên chuông, trung tâm thông báo trong ứng dụng và toast Windows gốc khi có bản mới.',
      updates_point_sha_title: 'Bộ cài xác minh SHA-256',
      updates_point_sha_desc: 'Bộ cài được tải kèm SHA256SUMS.txt và kiểm tra trước khi chạy. Không có đường cài nào bỏ qua bước này.',
      updates_point_confirm_title: 'Bạn xác nhận mọi lần cài',
      updates_point_confirm_desc: 'Không nâng cấp ngầm. PSManager chỉ cài sau khi bạn bấm nút hoặc gõ y.',
      updates_shot_alt: 'Trang Cập nhật của PSManager liệt kê phiên bản PowerShell và nguồn cài đặt',

      install_title: 'Cài đặt PSManager',
      install_lead: 'Chọn cách phù hợp. Cả ba cách dùng chung một bộ cài và cùng một bản phát hành.',
      install_tabs_label: 'Cách cài đặt',
      install_tab_winget: 'winget',
      install_tab_ps7: 'PowerShell 7',
      install_tab_ps51: 'Windows PowerShell 5.1',
      install_winget_caption: 'Cài từ kho cộng đồng winget. Sau đó chạy psmgr để mở giao diện terminal.',
      install_ps7_caption: 'Chạy trong PowerShell 7. Script cài đặt sẽ kiểm tra môi trường trước khi tải về.',
      install_ps51_caption: 'Dành cho Windows PowerShell 5.1 có sẵn trên Windows 10 và 11.',
      install_requirements: 'Yêu cầu Windows 10 hoặc 11 với PowerShell 5.1 trở lên. Cài cho riêng bạn không cần quyền quản trị.',
      install_note_title: 'Bản xem trước riêng tư',
      install_note_body: 'Khi kho mã còn riêng tư, hãy xác thực trước để script cài đặt truy cập được bản phát hành:',
      install_note_alt: 'Hoặc đặt biến môi trường PSMGR_GITHUB_TOKEN trước khi chạy script cài đặt.',

      faq_title: 'Câu hỏi thường gặp',
      faq_q1: 'Vì sao Windows SmartScreen cảnh báo?',
      faq_a1: 'Bộ cài chưa được ký số nên SmartScreen có thể hỏi lại. Hãy chọn More info rồi Run anyway, sau khi đã đối chiếu mã SHA-256 với SHA256SUMS.txt trong bản phát hành.',
      faq_q2: 'Cài từ kho riêng tư có được không?',
      faq_a2: 'Được, nếu bạn có quyền truy cập. Chạy gh auth login hoặc đặt PSMGR_GITHUB_TOKEN bằng token đọc được bản phát hành, rồi cài lại. Đặt PSMGR_DISABLE_UPDATE_CHECK=1 sẽ tắt hẳn việc kiểm tra cập nhật.',
      faq_q3: 'Có chạy trên Windows PowerShell 5.1 không?',
      faq_a3: 'Có. Mọi module chạy được trên Windows PowerShell 5.1 và PowerShell 7.4 trở lên, kể cả phần kiểm tra cập nhật và kho thông báo.',
      faq_q4: 'Gỡ cài đặt PSManager thế nào?',
      faq_a4: 'Vào Settings, Apps, Installed apps, hoặc chạy winget uninstall --id danhthanh4182.PSManager. Dữ liệu người dùng trong %LOCALAPPDATA%\\PSManager được giữ lại; xoá thư mục đó nếu muốn dọn sạch.',
      faq_q5: 'Thông báo cập nhật đến từ đâu?',
      faq_a5: 'PSManager đọc API bản phát hành GitHub của chính nó, tối đa một lần mỗi sáu giờ. Mỗi lần kiểm tra là một yêu cầu; đặt PSMGR_DISABLE_UPDATE_CHECK=1 để tắt và PSMGR_DISABLE_TOASTS=1 để tắt toast hệ thống.',

      cta_title: 'Sẵn sàng đặt PowerShell 7 làm mặc định?',
      cta_lead: 'Một câu lệnh là có CLI, TUI và ứng dụng desktop, tất cả dùng chung một bộ quản lý.',
      cta_primary: 'Cài đặt PSManager',
      cta_secondary: 'Đọc tài liệu',

      footer_tagline: 'Trình quản lý phiên bản PowerShell cho Windows, viết bằng PowerShell.',
      footer_product: 'Sản phẩm',
      footer_resources: 'Tài nguyên',
      footer_links_github: 'GitHub',
      footer_links_releases: 'Bản phát hành',
      footer_links_issues: 'Báo lỗi',
      footer_links_docs: 'Tài liệu',
      footer_links_license: 'Giấy phép MIT',
      footer_version_label: 'Phiên bản hiện tại',
      footer_disclaimer: 'Không liên kết với Microsoft. PowerShell là thương hiệu của Microsoft Corporation.',

      error_title: 'Trang này không tồn tại',
      error_lead: 'Liên kết có thể đã cũ hoặc trang đã được chuyển. Hãy quay về trang chủ PSManager.',
      error_back: 'Về trang chủ PSManager'
    }
  };

  var currentLang = 'en';

  function readStore(key) {
    try {
      return window.localStorage.getItem(key);
    } catch (err) {
      return null;
    }
  }

  function writeStore(key, value) {
    try {
      window.localStorage.setItem(key, value);
    } catch (err) {
      /* storage may be blocked; the page still works for this session */
    }
  }

  function dict() {
    return I18N[currentLang] || I18N.en;
  }

  function setThemeColor(theme) {
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) {
      meta.setAttribute('content', THEME_COLORS[theme] || THEME_COLORS.dark);
    }
  }

  function applyLang(lang) {
    currentLang = I18N[lang] ? lang : 'en';
    var strings = dict();
    var root = document.documentElement;

    root.setAttribute('lang', currentLang);

    document.querySelectorAll('[data-i18n]').forEach(function (el) {
      var value = strings[el.getAttribute('data-i18n')];
      if (typeof value === 'string') {
        el.textContent = value;
      }
    });

    document.querySelectorAll('[data-i18n-aria-label]').forEach(function (el) {
      var value = strings[el.getAttribute('data-i18n-aria-label')];
      if (typeof value === 'string') {
        el.setAttribute('aria-label', value);
      }
    });

    document.querySelectorAll('[data-i18n-alt]').forEach(function (el) {
      var value = strings[el.getAttribute('data-i18n-alt')];
      if (typeof value === 'string') {
        el.setAttribute('alt', value);
      }
    });

    var langButton = document.getElementById('lang-toggle');
    if (langButton) {
      langButton.textContent = currentLang === 'en' ? 'VI' : 'EN';
      langButton.setAttribute('aria-label', strings.lang_toggle_label);
    }

    writeStore(LANG_KEY, currentLang);
  }

  function applyTheme(theme) {
    var next = theme === 'light' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', next);
    setThemeColor(next);
    writeStore(THEME_KEY, next);
  }

  function closeMenu() {
    var header = document.querySelector('.site-header');
    var button = document.getElementById('menu-toggle');
    if (header) {
      header.classList.remove('nav-open');
    }
    if (button) {
      button.setAttribute('aria-expanded', 'false');
    }
  }

  function initTheme() {
    var stored = readStore(THEME_KEY);
    applyTheme(stored === 'light' ? 'light' : 'dark');
    var button = document.getElementById('theme-toggle');
    if (button) {
      button.addEventListener('click', function () {
        var next = document.documentElement.getAttribute('data-theme') === 'light' ? 'dark' : 'light';
        applyTheme(next);
      });
    }
  }

  function initLang() {
    var stored = readStore(LANG_KEY);
    applyLang(stored === 'vi' ? 'vi' : 'en');
    var button = document.getElementById('lang-toggle');
    if (button) {
      button.addEventListener('click', function () {
        applyLang(currentLang === 'en' ? 'vi' : 'en');
      });
    }
  }

  function initMenu() {
    var button = document.getElementById('menu-toggle');
    var header = document.querySelector('.site-header');
    var nav = document.getElementById('site-nav');
    if (!button || !header) {
      return;
    }

    button.addEventListener('click', function () {
      var open = header.classList.toggle('nav-open');
      button.setAttribute('aria-expanded', open ? 'true' : 'false');
    });

    if (nav) {
      nav.addEventListener('click', function (event) {
        if (event.target && event.target.closest('a')) {
          closeMenu();
        }
      });
    }

    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape' && header.classList.contains('nav-open')) {
        closeMenu();
        button.focus();
      }
    });

    window.addEventListener('resize', function () {
      if (window.innerWidth > 820) {
        closeMenu();
      }
    });
  }

  function initTabs() {
    document.querySelectorAll('[role="tablist"]').forEach(function (list) {
      var tabs = Array.prototype.slice.call(list.querySelectorAll('[role="tab"]'));
      if (!tabs.length) {
        return;
      }

      function select(tab, moveFocus) {
        tabs.forEach(function (item) {
          var selected = item === tab;
          item.setAttribute('aria-selected', selected ? 'true' : 'false');
          item.setAttribute('tabindex', selected ? '0' : '-1');
          var panel = document.getElementById(item.getAttribute('aria-controls'));
          if (panel) {
            panel.hidden = !selected;
          }
        });
        if (moveFocus) {
          tab.focus();
        }
      }

      tabs.forEach(function (tab, index) {
        tab.addEventListener('click', function () {
          select(tab, false);
        });

        tab.addEventListener('keydown', function (event) {
          var next = null;
          if (event.key === 'ArrowRight') {
            next = (index + 1) % tabs.length;
          } else if (event.key === 'ArrowLeft') {
            next = (index - 1 + tabs.length) % tabs.length;
          } else if (event.key === 'Home') {
            next = 0;
          } else if (event.key === 'End') {
            next = tabs.length - 1;
          }
          if (next !== null) {
            event.preventDefault();
            select(tabs[next], true);
          }
        });
      });
    });
  }

  function legacyCopy(text) {
    var area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', 'readonly');
    area.style.position = 'fixed';
    area.style.top = '-1000px';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    var ok = false;
    try {
      ok = document.execCommand('copy');
    } catch (err) {
      ok = false;
    }
    document.body.removeChild(area);
    return ok;
  }

  function copyText(text) {
    return new Promise(function (resolve) {
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(function () {
          resolve(true);
        }, function () {
          resolve(legacyCopy(text));
        });
        return;
      }
      resolve(legacyCopy(text));
    });
  }

  function initCopy() {
    document.querySelectorAll('[data-copy]').forEach(function (button) {
      button.addEventListener('click', function () {
        var target = document.getElementById(button.getAttribute('data-copy'));
        if (!target) {
          return;
        }
        var scope = button.closest('[data-copy-scope]');
        var status = scope ? scope.querySelector('[data-copy-status]') : null;

        copyText(target.textContent.replace(/\s+$/, '')).then(function (ok) {
          if (!status) {
            return;
          }
          status.textContent = dict()[ok ? 'copy_ok' : 'copy_fail'];
          status.classList.toggle('is-error', !ok);
          if (status.dataset.timer) {
            window.clearTimeout(Number(status.dataset.timer));
          }
          status.dataset.timer = String(window.setTimeout(function () {
            status.textContent = '';
            status.classList.remove('is-error');
            delete status.dataset.timer;
          }, 2000));
        });
      });
    });
  }

  function initReveal() {
    var items = Array.prototype.slice.call(document.querySelectorAll('.reveal'));
    if (!items.length) {
      return;
    }

    var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduce || !('IntersectionObserver' in window)) {
      items.forEach(function (item) {
        item.classList.add('is-visible');
      });
      return;
    }

    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          show(entry.target);
        }
      });
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });

    var pending = items.length;

    function show(item) {
      if (item.classList.contains('is-visible')) {
        return;
      }
      item.classList.add('is-visible');
      observer.unobserve(item);
      pending -= 1;
    }

    // Anchor jumps and fast scrolls can skip past sections, so reveal anything
    // at or above the fold rather than leave it invisible above the viewport.
    var ticking = false;

    function onScroll() {
      if (ticking) {
        return;
      }
      ticking = true;
      window.requestAnimationFrame(function () {
        ticking = false;
        var fold = window.innerHeight;
        items.forEach(function (item) {
          if (item.getBoundingClientRect().top < fold) {
            show(item);
          }
        });
        if (pending <= 0) {
          window.removeEventListener('scroll', onScroll);
        }
      });
    }

    items.forEach(function (item) {
      observer.observe(item);
    });

    window.addEventListener('scroll', onScroll, { passive: true });
    onScroll();
  }

  function initYear() {
    var year = document.getElementById('footer-year');
    if (year) {
      year.textContent = String(new Date().getFullYear());
    }
  }

  function init() {
    initTheme();
    initLang();
    initMenu();
    initTabs();
    initCopy();
    initReveal();
    initYear();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
}());
