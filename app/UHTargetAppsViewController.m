#import "UHTargetAppsViewController.h"
#import <spawn.h>
#import <sys/wait.h>

@interface UHAppInfo : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, strong) UIImage *icon;
@property (nonatomic, assign) BOOL isEnabled;
@end

@implementation UHAppInfo
@end

@interface UIImage (PrivateIcon)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

@interface UHTargetAppsViewController ()
@property (nonatomic, strong) NSMutableArray<UHAppInfo *> *allApps;
@property (nonatomic, strong) NSMutableArray<UHAppInfo *> *filteredApps;
@property (nonatomic, strong) NSMutableSet<NSString *> *enabledBundleIDs;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, copy) NSString *configPath;
@property (nonatomic, assign) BOOL isSearching;
@end

@implementation UHTargetAppsViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	
	self.title = @"UltraHide Pro";
	self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
	
	self.allApps = [NSMutableArray array];
	self.filteredApps = [NSMutableArray array];
	self.enabledBundleIDs = [NSMutableSet set];
	
	// Resolve config path & load existing settings
	[self resolveConfigPath];
	[self loadConfiguration];
	
	// Setup Search
	self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
	self.searchController.searchResultsUpdater = self;
	self.searchController.obscuresBackgroundDuringPresentation = NO;
	self.searchController.searchBar.placeholder = @"Tìm kiếm ứng dụng hoặc Bundle ID...";
	self.navigationItem.searchController = self.searchController;
	self.definesPresentationContext = YES;
	
	// Navigation buttons
	UIBarButtonItem *addBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
	                                                                        target:self
	                                                                        action:@selector(addCustomBundleIDPrompt)];
	
	UIBarButtonItem *saveBtn = [[UIBarButtonItem alloc] initWithTitle:@"Lưu"
	                                                            style:UIBarButtonItemStyleDone
	                                                           target:self
	                                                           action:@selector(saveAndApply)];
	
	self.navigationItem.leftBarButtonItem = addBtn;
	self.navigationItem.rightBarButtonItem = saveBtn;
	
	// Pull to refresh
	UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
	[refreshControl addTarget:self action:@selector(handleRefresh:) forControlEvents:UIControlEventValueChanged];
	self.refreshControl = refreshControl;
	
	// Load installed apps dynamically from the system
	[self loadInstalledApps];
}

- (void)handleRefresh:(UIRefreshControl *)refresh {
	[self loadConfiguration];
	[self loadInstalledApps];
	[refresh endRefreshing];
}

- (void)resolveConfigPath {
	NSArray *candidates = @[
		@"/var/jb/Library/UltraHidePro/config.plist",
		@"/Library/UltraHidePro/config.plist",
		@"/var/jb/etc/ultrahidepro/config.plist"
	];
	NSFileManager *fm = [NSFileManager defaultManager];
	for (NSString *p in candidates) {
		if ([fm fileExistsAtPath:p]) {
			self.configPath = p;
			return;
		}
	}
	self.configPath = candidates.firstObject;
}

- (void)loadConfiguration {
	[self.enabledBundleIDs removeAllObjects];
	NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:self.configPath];
	if (dict) {
		NSArray *targets = dict[@"target_apps"];
		if ([targets isKindOfClass:[NSArray class]]) {
			for (id item in targets) {
				if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] > 0) {
					[self.enabledBundleIDs addObject:(NSString *)item];
				}
			}
		}
	}
}

- (BOOL)saveConfiguration {
	NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:self.configPath];
	if (!dict) {
		dict = [NSMutableDictionary dictionary];
	}
	
	NSArray *sortedTargets = [[self.enabledBundleIDs allObjects] sortedArrayUsingSelector:@selector(compare:)];
	dict[@"target_apps"] = sortedTargets;
	
	// Ensure parent directory exists with 0777 permissions
	NSString *parentDir = [self.configPath stringByDeletingLastPathComponent];
	NSFileManager *fm = [NSFileManager defaultManager];
	[fm createDirectoryAtPath:parentDir
	withIntermediateDirectories:YES
	               attributes:@{NSFilePosixPermissions: @0777}
	                    error:nil];
	
	// Try writing atomically, then non-atomically, then via NSPropertyListSerialization
	BOOL success = [dict writeToFile:self.configPath atomically:YES];
	if (!success) {
		success = [dict writeToFile:self.configPath atomically:NO];
	}
	if (!success) {
		NSError *err = nil;
		NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict
		                                                          format:NSPropertyListXMLFormat_v1_0
		                                                         options:0
		                                                           error:&err];
		if (data) {
			success = [data writeToFile:self.configPath options:0 error:&err];
		}
	}
	
	// Ensure file has 0666 permissions so any process can read/write it
	[fm setAttributes:@{NSFilePosixPermissions: @0666} ofItemAtPath:self.configPath error:nil];
	
	NSLog(@"[UltraHideProApp] saveConfiguration -> success=%d, count=%lu at %@",
	      success, (unsigned long)sortedTargets.count, self.configPath);
	return success;
}

#pragma mark - Icon Loading Helper

- (UIImage *)iconForBundleID:(NSString *)bundleID bundlePath:(NSString *)bundlePath {
	if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
		UIImage *img = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:2 scale:[UIScreen mainScreen].scale];
		if (img) return img;
		img = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:0 scale:[UIScreen mainScreen].scale];
		if (img) return img;
	}
	
	if (bundlePath) {
		NSString *infoPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
		NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
		NSDictionary *icons = info[@"CFBundleIcons"];
		NSArray *files = icons[@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"];
		if (!files || files.count == 0) {
			files = info[@"CFBundleIconFiles"];
		}
		NSFileManager *fm = [NSFileManager defaultManager];
		if (files && files.count > 0) {
			for (NSString *iconName in [files reverseObjectEnumerator]) {
				NSArray *suffixes = @[@"@3x.png", @"@2x.png", @".png", @"60x60@2x.png", @"60x60@3x.png"];
				for (NSString *sfx in suffixes) {
					NSString *p = [bundlePath stringByAppendingPathComponent:[iconName stringByAppendingString:sfx]];
					if ([fm fileExistsAtPath:p]) {
						UIImage *img = [UIImage imageWithContentsOfFile:p];
						if (img) return img;
					}
				}
				NSString *p = [bundlePath stringByAppendingPathComponent:iconName];
				if ([fm fileExistsAtPath:p]) {
					UIImage *img = [UIImage imageWithContentsOfFile:p];
					if (img) return img;
				}
			}
		}
		NSArray *commonNames = @[@"AppIcon60x60@2x.png", @"AppIcon60x60@3x.png", @"AppIcon@2x.png", @"Icon-60@2x.png", @"Icon.png"];
		for (NSString *cName in commonNames) {
			NSString *p = [bundlePath stringByAppendingPathComponent:cName];
			if ([fm fileExistsAtPath:p]) {
				UIImage *img = [UIImage imageWithContentsOfFile:p];
				if (img) return img;
			}
		}
	}
	return nil;
}

#pragma mark - Process App Bundle

- (void)processAppBundleAtPath:(NSString *)bundlePath appMap:(NSMutableDictionary<NSString *, UHAppInfo *> *)appMap {
	NSString *infoPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
	NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
	if (!info) return;
	
	NSString *bid = info[@"CFBundleIdentifier"];
	if (!bid || bid.length == 0) return;
	if (appMap[bid]) return; // Already registered
	
	// Skip web apps, widgets, or internal helpers
	if ([bid containsString:@"com.apple.webapp"] || [bid hasPrefix:@"com.apple.WebKit"]) return;
	
	NSString *name = info[@"CFBundleDisplayName"];
	if (!name || name.length == 0) {
		name = info[@"CFBundleName"];
	}
	if (!name || name.length == 0) {
		name = [[bundlePath lastPathComponent] stringByDeletingPathExtension];
	}
	
	UHAppInfo *app = [[UHAppInfo alloc] init];
	app.bundleID = bid;
	app.displayName = name;
	app.isEnabled = [self.enabledBundleIDs containsObject:bid];
	app.icon = [self iconForBundleID:bid bundlePath:bundlePath];
	appMap[bid] = app;
}

#pragma mark - Load Installed Apps

- (void)loadInstalledApps {
	[self.allApps removeAllObjects];
	NSMutableDictionary<NSString *, UHAppInfo *> *appMap = [NSMutableDictionary dictionary];
	
	// 1. Discover via LaunchServices Private APIs
	Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
	if (workspaceClass) {
		id workspace = nil;
		if ([workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
			workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
		}
		if (workspace) {
			NSArray *proxies = nil;
			if ([workspace respondsToSelector:@selector(allInstalledApplications)]) {
				proxies = [workspace performSelector:@selector(allInstalledApplications)];
			}
			if ((!proxies || proxies.count == 0) && [workspace respondsToSelector:@selector(allApplications)]) {
				proxies = [workspace performSelector:@selector(allApplications)];
			}
			if ((!proxies || proxies.count == 0) && [workspace respondsToSelector:@selector(applicationsOfType:)]) {
				proxies = [workspace performSelector:@selector(applicationsOfType:) withObject:@(0)];
			}
			
			if (proxies && [proxies isKindOfClass:[NSArray class]]) {
				for (id proxy in proxies) {
					NSString *bid = nil;
					if ([proxy respondsToSelector:@selector(bundleIdentifier)]) {
						bid = [proxy performSelector:@selector(bundleIdentifier)];
					}
					if (!bid || bid.length == 0) continue;
					if ([bid containsString:@"com.apple.webapp"] || [bid hasPrefix:@"com.apple.WebKit"]) continue;
					
					NSString *appType = @"User";
					if ([proxy respondsToSelector:@selector(applicationType)]) {
						appType = [proxy performSelector:@selector(applicationType)];
					}
					if (![appType isEqualToString:@"User"] && ![self.enabledBundleIDs containsObject:bid]) {
						if (![bid hasPrefix:@"com.apple.mobilesafari"] &&
						    ![bid hasPrefix:@"com.apple.AppStore"] &&
						    ![bid hasPrefix:@"com.apple.Preferences"]) {
							continue;
						}
					}
					
					NSString *name = bid;
					if ([proxy respondsToSelector:@selector(localizedName)]) {
						NSString *loc = [proxy performSelector:@selector(localizedName)];
						if (loc && loc.length > 0) name = loc;
					} else if ([proxy respondsToSelector:@selector(itemName)]) {
						NSString *item = [proxy performSelector:@selector(itemName)];
						if (item && item.length > 0) name = item;
					}
					
					UHAppInfo *info = [[UHAppInfo alloc] init];
					info.bundleID = bid;
					info.displayName = name;
					info.isEnabled = [self.enabledBundleIDs containsObject:bid];
					info.icon = [self iconForBundleID:bid bundlePath:nil];
					appMap[bid] = info;
				}
			}
		}
	}
	
	// 2. Discover via Direct Filesystem Scan of User Applications Container
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray *userContainerBases = @[
		@"/var/containers/Bundle/Application",
		@"/private/var/containers/Bundle/Application"
	];
	for (NSString *base in userContainerBases) {
		if (![fm fileExistsAtPath:base]) continue;
		NSArray *uuidFolders = [fm contentsOfDirectoryAtPath:base error:nil];
		if (!uuidFolders) continue;
		for (NSString *uuid in uuidFolders) {
			NSString *uuidPath = [base stringByAppendingPathComponent:uuid];
			NSArray *items = [fm contentsOfDirectoryAtPath:uuidPath error:nil];
			if (!items) continue;
			for (NSString *item in items) {
				if ([item.pathExtension isEqualToString:@"app"]) {
					NSString *appBundlePath = [uuidPath stringByAppendingPathComponent:item];
					[self processAppBundleAtPath:appBundlePath appMap:appMap];
				}
			}
		}
	}
	
	// 3. Discover via Direct Filesystem Scan of System & Jailbreak Applications
	NSArray *systemAppDirs = @[
		@"/Applications",
		@"/var/jb/Applications",
		@"/private/var/jb/Applications"
	];
	for (NSString *sysDir in systemAppDirs) {
		if (![fm fileExistsAtPath:sysDir]) continue;
		NSArray *apps = [fm contentsOfDirectoryAtPath:sysDir error:nil];
		if (!apps) continue;
		for (NSString *item in apps) {
			if ([item.pathExtension isEqualToString:@"app"]) {
				if ([item.lowercaseString containsString:@"ultrahidepro"]) continue;
				NSString *appBundlePath = [sysDir stringByAppendingPathComponent:item];
				[self processAppBundleAtPath:appBundlePath appMap:appMap];
			}
		}
	}
	
	// 4. Any enabled bundle IDs from config.plist not yet registered in appMap
	for (NSString *bid in self.enabledBundleIDs) {
		if (!appMap[bid]) {
			UHAppInfo *info = [[UHAppInfo alloc] init];
			info.bundleID = bid;
			info.displayName = bid;
			info.isEnabled = YES;
			info.icon = [self iconForBundleID:bid bundlePath:nil];
			appMap[bid] = info;
		}
	}
	
	// Sort: Enabled apps first, then alphabetically by display name
	NSArray *sorted = [appMap.allValues sortedArrayUsingComparator:^NSComparisonResult(UHAppInfo *a, UHAppInfo *b) {
		if (a.isEnabled != b.isEnabled) {
			return a.isEnabled ? NSOrderedAscending : NSOrderedDescending;
		}
		return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
	}];
	
	[self.allApps addObjectsFromArray:sorted];
	[self.tableView reloadData];
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
	NSString *text = [searchController.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (text.length == 0) {
		self.isSearching = NO;
		[self.filteredApps removeAllObjects];
	} else {
		self.isSearching = YES;
		[self.filteredApps removeAllObjects];
		for (UHAppInfo *app in self.allApps) {
			if ([app.displayName localizedCaseInsensitiveContainsString:text] ||
			    [app.bundleID localizedCaseInsensitiveContainsString:text]) {
				[self.filteredApps addObject:app];
			}
		}
	}
	[self.tableView reloadData];
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return self.isSearching ? 1 : 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	if (self.isSearching) return @"Kết quả tìm kiếm";
	if (section == 0) return @"Trạng thái bảo vệ";
	return @"Danh sách ứng dụng trên thiết bị";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (!self.isSearching && section == 1) {
		return [NSString stringWithFormat:@"Đã tìm thấy %lu ứng dụng (Đang bảo vệ: %lu ứng dụng).\nKéo xuống để làm mới danh sách.",
		        (unsigned long)self.allApps.count, (unsigned long)self.enabledBundleIDs.count];
	}
	return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	if (self.isSearching) {
		return self.filteredApps.count;
	}
	if (section == 0) return 1;
	return self.allApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	if (!self.isSearching && indexPath.section == 0) {
		UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"StatusCell"];
		if (!cell) {
			cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"StatusCell"];
		}
		cell.textLabel.text = @"Bảo vệ UltraHide Pro";
		cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
		cell.detailTextLabel.text = [NSString stringWithFormat:@"Đã kích hoạt cho %lu ứng dụng mục tiêu", (unsigned long)self.enabledBundleIDs.count];
		cell.detailTextLabel.textColor = [UIColor systemGreenColor];
		cell.accessoryType = UITableViewCellAccessoryCheckmark;
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
		return cell;
	}
	
	static NSString *cellID = @"AppCell";
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
	if (!cell) {
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
	}
	
	UHAppInfo *info = self.isSearching ? self.filteredApps[indexPath.row] : self.allApps[indexPath.row];
	cell.textLabel.text = info.displayName;
	cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
	cell.detailTextLabel.text = info.bundleID;
	cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
	
	if (info.icon) {
		cell.imageView.image = info.icon;
		cell.imageView.layer.cornerRadius = 8;
		cell.imageView.layer.masksToBounds = YES;
	} else {
		cell.imageView.image = nil;
	}
	
	UISwitch *sw = [[UISwitch alloc] init];
	sw.on = info.isEnabled;
	sw.tag = indexPath.row;
	[sw addTarget:self action:@selector(switchToggled:) forControlEvents:UIControlEventValueChanged];
	cell.accessoryView = sw;
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	
	return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
	return 64.0;
}

#pragma mark - Actions

- (void)switchToggled:(UISwitch *)sender {
	UHAppInfo *info = self.isSearching ? self.filteredApps[sender.tag] : self.allApps[sender.tag];
	info.isEnabled = sender.isOn;
	
	if (sender.isOn) {
		[self.enabledBundleIDs addObject:info.bundleID];
	} else {
		[self.enabledBundleIDs removeObject:info.bundleID];
	}
	
	// Auto save to config.plist immediately
	[self saveConfiguration];
	
	if (!self.isSearching) {
		[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
	}
}

- (void)saveAndApply {
	BOOL success = [self saveConfiguration];
	
	NSString *title = success ? @"Đã lưu thành công!" : @"Lỗi lưu cấu hình!";
	NSString *msg = success ?
		[NSString stringWithFormat:@"Đã cập nhật danh sách %lu ứng dụng được bảo vệ tại:\n%@", (unsigned long)self.enabledBundleIDs.count, self.configPath] :
		[NSString stringWithFormat:@"Không thể ghi vào file %@. Vui lòng kiểm tra quyền truy cập.", self.configPath];
	
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
	                                                               message:msg
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	
	if (success) {
		[alert addAction:[UIAlertAction actionWithTitle:@"Respring ngay"
		                                         style:UIAlertActionStyleDestructive
		                                       handler:^(UIAlertAction *action) {
			[self triggerRespring];
		}]];
	}
	
	[alert addAction:[UIAlertAction actionWithTitle:@"Đóng"
	                                         style:UIAlertActionStyleCancel
	                                       handler:nil]];
	
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)addCustomBundleIDPrompt {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Thêm ứng dụng thủ công"
	                                                               message:@"Nhập Bundle Identifier của ứng dụng (ví dụ: com.mbbank.mobilebanking):"
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	
	[alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
		textField.placeholder = @"com.example.app";
		textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
		textField.autocorrectionType = UITextAutocorrectionTypeNo;
	}];
	
	[alert addAction:[UIAlertAction actionWithTitle:@"Thêm" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		NSString *input = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (input.length > 0) {
			[self.enabledBundleIDs addObject:input];
			[self saveConfiguration];
			[self loadInstalledApps];
		}
	}]];
	
	[alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)triggerRespring {
	pid_t pid;
	const char *argv[] = {"killall", "-9", "SpringBoard", NULL};
	if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/usr/bin/killall"]) {
		posix_spawn(&pid, "/var/jb/usr/bin/killall", NULL, NULL, (char *const *)argv, NULL);
	} else {
		posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)argv, NULL);
	}
}

@end
