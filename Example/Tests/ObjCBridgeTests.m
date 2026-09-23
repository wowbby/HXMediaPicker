#import <XCTest/XCTest.h>
#import <HXMediaPicker/HXMediaPicker-Swift.h>

@interface ObjCBridgeTests : XCTestCase
@end

@implementation ObjCBridgeTests
- (void)testAllOptionsAndObjectiveCSelectorReportInvalidPresenterOnMainThread {
    HXMediaPickerOptions *options = [[HXMediaPickerOptions alloc] init];
    options.source = HXMediaPickerSourceLibrary;
    options.mediaType = HXMediaPickerMediaTypePhoto;
    options.maximumSelectedCount = 9;
    options.selectionRequiresConfirmation = YES;
    options.allowsEditing = YES;
    options.automaticallyEditsSinglePhoto = NO;
    options.cropOnly = YES;
    options.allowsCamera = YES;
    options.saveToPhotoLibrary = NO;
    options.minimumVideoDuration = 1;
    options.maximumVideoDuration = 120;
    options.maximumVideoFileSize = 1024 * 1024;
    options.imageTargetSize = CGSizeMake(1920, 1080);
    options.appearance = HXMediaPickerAppearanceAutomatic;
    options.themeColor = UIColor.systemBlueColor;
    options.willPresent = ^{ XCTFail(@"An unattached controller must never present"); };
    options.didDismiss = ^{ XCTFail(@"An unpresented picker must never dismiss"); };

    XCTestExpectation *done = [self expectationWithDescription:@"Objective-C callback"];
    done.assertForOverFulfill = YES;
    UIViewController *presenter = [[UIViewController alloc] init];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [HXMediaPicker presentFromViewController:presenter options:options
            completion:^(HXMediaPickerResult *result, NSError *error) {
                XCTAssertTrue(NSThread.isMainThread);
                XCTAssertNil(result);
                XCTAssertEqualObjects(error.domain, @"HXMediaPicker");
                XCTAssertEqual(error.code, 2);
                // Compile every result property as seen by the real Objective-C consumers.
                NSArray<UIImage *> *images = result.images;
                NSArray<NSURL *> *videos = result.videoURLs;
                BOOL original = result.isOriginal;
                XCTAssertNil(images);
                XCTAssertNil(videos);
                XCTAssertFalse(original);
                [done fulfill];
            } cancel:^{ XCTFail(@"Invalid presentation is an error, not cancellation"); }];
    });
    [self waitForExpectations:@[done] timeout:5];
}
@end
