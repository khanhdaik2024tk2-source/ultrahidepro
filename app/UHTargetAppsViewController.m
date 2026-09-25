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
	
	// Resolve config path
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
	
	// Load apps
	[self loadInstalledApps];
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
				if ([item isKindOfClass:[NSString class]]) {
					[self.enabledBundleIDs addObject:item];
				}
			}
		}
	}
}

- (void)saveConfiguration {
	NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:self.configPath];
	if (!dict) {
		dict = [NSMutableDictionary dictionary];
	}
	
	NSArray *sortedTargets = [[self.enabledBundleIDs allObjects] sortedArrayUsingSelector:@selector(compare:)];
	dict[@"target_apps"] = sortedTargets;
	
	// Ensure parent directory exists
	NSString *parentDir = [self.configPath stringByDeletingLastPathComponent];
	[[NSFileManager defaultManager] createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:nil];
	
	BOOL success = [dict writeToFile:self.configPath atomically:YES];
	if (success) {
		NSLog(@"[UltraHideProApp] Saved %lu target apps to %@", (unsigned long)sortedTargets.count, self.configPath);
	}
}

- (void)loadInstalledApps {
	[self.allApps removeAllObjects];
	NSMutableDictionary<NSString *, UHAppInfo *> *appMap = [NSMutableDictionary dictionary];
	
	// Method 1: LSApplicationWorkspace private API
	Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
	if (workspaceClass) {
		id workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
		if (workspace && [workspace respondsToSelector:@selector(allApplications)]) {
			NSArray *proxies = [workspace performSelector:@selector(allApplications)];
			for (id proxy in proxies) {
				NSString *bid = [proxy performSelector:@selector(bundleIdentifier)];
				if (!bid || bid.length == 0) continue;
				
				// Skip internal daemons and non-UI placeholders
				NSString *appType = @"User";
				if ([proxy respondsToSelector:@selector(applicationType)]) {
					appType = [proxy performSelector:@selector(applicationType)];
				}
				if (![appType isEqualToString:@"User"] && ![self.enabledBundleIDs containsObject:bid]) {
					// Only keep system apps if they are already in enabled target apps
					if (![bid hasPrefix:@"com.apple.mobilesafari"]) continue;
				}
				
				NSString *name = bid;
				if ([proxy respondsToSelector:@selector(localizedName)]) {
					NSString *loc = [proxy performSelector:@selector(localizedName)];
					if (loc && loc.length > 0) name = loc;
				}
				
				UHAppInfo *info = [[UHAppInfo alloc] init];
				info.bundleID = bid;
				info.displayName = name;
				info.isEnabled = [self.enabledBundleIDs containsObject:bid];
				
				// Try fetching icon
				if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
					info.icon = [UIImage _applicationIconImageForBundleIdentifier:bid format:2 scale:[UIScreen mainScreen].scale];
				}
				
				appMap[bid] = info;
			}
		}
	}
	
	// Add any target app from config that wasn't found in LSApplicationWorkspace
	for (NSString *bid in self.enabledBundleIDs) {
		if (!appMap[bid]) {
			UHAppInfo *info = [[UHAppInfo alloc] init];
			info.bundleID = bid;
			info.displayName = bid;
			info.isEnabled = YES;
			if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
				info.icon = [UIImage _applicationIconImageForBundleIdentifier:bid format:2 scale:[UIScreen mainScreen].scale];
			}
			appMap[bid] = info;
		}
	}
	
	// Sort: Enabled apps first, then alphabetically
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
	return @"Danh sách ứng dụng";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (!self.isSearching && section == 1) {
		return [NSString stringWithFormat:@"Tổng cộng: %lu ứng dụng (Đã bảo vệ: %lu)",
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
	
	// Auto save
	[self saveConfiguration];
	
	if (!self.isSearching) {
		[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
	}
}

- (void)saveAndApply {
	[self saveConfiguration];
	
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Đã lưu thành công!"
	                                                               message:[NSString stringWithFormat:@"Đã cập nhật danh sách %lu ứng dụng được bảo vệ.", (unsigned long)self.enabledBundleIDs.count]
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	
	[alert addAction:[UIAlertAction actionWithTitle:@"Respring ngay"
	                                         style:UIAlertActionStyleDestructive
	                                       handler:^(UIAlertAction *action) {
		[self triggerRespring];
	}]];
	
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
	posix_spawn(&pid, "/var/jb/usr/bin/killall", NULL, NULL, (char *const *)argv, NULL);
}

@end
