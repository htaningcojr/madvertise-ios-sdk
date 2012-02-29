
// Copyright 2011 madvertise Mobile Advertising GmbH
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "MadvertiseView.h"
#import "MRAdView.h"

// PRIVATE METHODS

@interface MadvertiseView ()
- (CGSize) getScreenResolution;
- (CGSize) getParentViewDimensions;
- (NSString*) getDeviceOrientation;
- (MadvertiseView*)initWithDelegate:(id<MadvertiseDelegationProtocol>)delegate withClass:(MadvertiseAdClass)adClassValue secondsToRefresh:(int)secondsToRefresh;
- (void) createAdReloadTimer;
- (void) displayView;
- (void) stopTimer;
- (void)swapView:(UIView*)newView oldView:(UIView*) oldView;
- (void)loadAd;       // load a new ad into an existing MadvertiseView
- (void)openInAppBrowserWithUrl:(NSString*)url;
                      // Ads should not be cached, nor should you request more than one ad per minute
@end


@implementation MadvertiseView

@synthesize currentAd;
@synthesize inAppLandingPageController;
@synthesize request;
@synthesize currentView;
@synthesize timer;
@synthesize conn;
@synthesize receivedData;
@synthesize madDelegate;
@synthesize rootViewController;

NSString * const MadvertiseAdClass_toString[] = {
  @"mma",
  @"medium_rectangle",
  @"leaderboard",
  @"fullscreen",
  @"portrait",
  @"landscape",
  @"rich_media"
};

// METHODS
- (void) dealloc {
  MadLog(@"Call dealloc in MadvertiseView");
  
  [[NSNotificationCenter defaultCenter] removeObserver: self name:UIApplicationDidEnterBackgroundNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver: self name:UIApplicationDidBecomeActiveNotification object:nil];

  //[self.conn cancel];
  self.conn = nil;
  self.request = nil;
  self.receivedData = nil;
  self.rootViewController = nil;

  if (self.timer) {
    [self stopTimer];
    self.timer = nil;
  }

  [inAppLandingPageController release];
  self.inAppLandingPageController = nil;
  self.madDelegate = nil;
    
  if(self.currentView) {
    self.currentView.delegate = nil;
      
      if([self.currentView respondsToSelector:@selector(stopLoading)]) {
          [self.currentView stopLoading];
      }
    
    self.currentView = nil;
  }
  
  self.currentAd   = nil;
    
  [lock release];
  lock = nil;

  [super dealloc];
}

+ (MadvertiseView*)loadRichMediaAdWithDelegate:(id<MadvertiseDelegationProtocol>)delegate placementType:(MRAdViewPlacementType) placementType {
  return [self loadAdWithDelegate:delegate withClass:MadvertiseAdClassRichMedia placementType:placementType secondsToRefresh:-1];
}

// main-constructor
+ (MadvertiseView*)loadAdWithDelegate:(id<MadvertiseDelegationProtocol>)delegate withClass:(MadvertiseAdClass)adClassValue placementType:(MRAdViewPlacementType) placementType secondsToRefresh:(int)secondsToRefresh {
  BOOL enableDebug = NO;

#ifdef DEBUG
  enableDebug = YES;
#endif

  // debugging
  if([delegate respondsToSelector:@selector(debugEnabled)]){
    enableDebug = [delegate debugEnabled];
  }

  // Download-Tracker
  if([delegate respondsToSelector:@selector(downloadTrackerEnabled)]){
    if([delegate downloadTrackerEnabled] == YES){
      [MadvertiseTracker setDebugMode: enableDebug];
      [MadvertiseTracker setProductToken:[delegate appId]];
      [MadvertiseTracker enable];
    }
  }
    
  // handle special rich media case
  if (adClassValue == MadvertiseAdClassRichMedia) {
      secondsToRefresh = -1;
  }
    
  return [[[MadvertiseView alloc] initWithDelegate:delegate withClass:adClassValue secondsToRefresh:secondsToRefresh] autorelease];
}

+ (void) handlerWithObserver:(id) observer AndSelector:(SEL) selector ForEvent:(NSString*) event {
    [[NSNotificationCenter defaultCenter] addObserver:observer selector:selector name:event object:nil];
}

- (void)removeFromSuperview {
  [self retain];
  [self stopTimer];
  [currentView removeFromSuperview];
  [super removeFromSuperview];
  [self release];
}

- (void)place_at_x:(int) x_pos y:(int) y_pos {
  x = x_pos;
  y = y_pos;

  if (currentAdClass == MadvertiseAdClassMediumRectangle) {
    self.frame = CGRectMake(x_pos, y_pos, 300, 250);
  } else if(currentAdClass == MadvertiseAdClassMMA) {
    self.frame = CGRectMake(x_pos, y_pos, 320, 53);
  } else if(currentAdClass == MadvertiseAdClassLeaderboard) {
    self.frame = CGRectMake(x_pos, y_pos, 728, 90);
  } else if(currentAdClass == MadvertiseAdClassFullscreen) {
    self.frame = CGRectMake(x_pos, y_pos, 768, 768);
  } else if(currentAdClass == MadvertiseAdClassPortrait) {
    self.frame = CGRectMake(x_pos, y_pos, 766, 66);
  } else if(currentAdClass == MadvertiseAdClassLandscape) {
    self.frame = CGRectMake(x_pos, y_pos, 1024, 66);
  } else if(currentAdClass == MadvertiseAdClassRichMedia) {
    x = 0;
    y = 0;
    CGRect screen     = [[UIScreen mainScreen] bounds];
    self.frame = CGRectMake(0, 0, screen.size.width, screen.size.height);
  }
}

// helper method for initialization
- (MadvertiseView*)initWithDelegate:(id<MadvertiseDelegationProtocol>)delegate withClass:(MadvertiseAdClass)adClassValue secondsToRefresh:(int)secondsToRefresh {

  if ((self = [super init])) {
    MadLog(@"madvertise SDK %@", MADVERTISE_SDK_VERION);

    self.clipsToBounds = YES;

    // just a dummy placeholder
    self.currentView = [[UIWebView alloc] initWithFrame:CGRectMake(0,0, 0,0)];
    [self addSubview:self.currentView];
    [currentView release];
    
    currentAdClass     = adClassValue;

    interval            = secondsToRefresh;
    request             = nil;
    receivedData        = nil;
    responseCode        = 200;
    isBannerMode        = YES;
    timer               = nil;
      
    isExpanded = false;

    madDelegate  = delegate;

    // load first ad
    lock = [[NSLock alloc] init];
    [self loadAd];
    [self createAdReloadTimer];

    animationDuration = 0.75;
    

    if([madDelegate respondsToSelector:@selector(durationOfBannerAnimation)]) {
      animationDuration = [madDelegate durationOfBannerAnimation];
    }

    // Notifications
    [[NSNotificationCenter defaultCenter] addObserver: self selector:@selector(stopTimer) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver: self selector:@selector(createAdReloadTimer) name:UIApplicationDidBecomeActiveNotification object:nil];
  }

  return self;
}


#pragma mark - server connection handling

// check, if response is OK
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSHTTPURLResponse *)response {
    MadLog(@"%@ %i", @"Received response code: ", [response statusCode]);
    responseCode = [response statusCode];
    [receivedData setLength:0];
    
    // debugging
    if ([madDelegate respondsToSelector:@selector(debugEnabled)] && [madDelegate debugEnabled]) {
        MadLog(@"%@",[[response allHeaderFields] objectForKey:@"X-Madvertise-Debug"]);
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    MadLog(@"Received data from Ad Server");
    [receivedData appendData:data];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    MadLog(@"Failed to receive ad");
    MadLog(@"%@",[error description]);

    // dispatch status notification
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseAdLoadFailed" object:[NSNumber numberWithInt:responseCode]];

    self.request = nil;
}


- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)cachedResponse {
    return nil;
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    if (responseCode == 200 && !isExpanded) {
        // parse response
        MadLog(@"Deserializing json");
        
        NSDictionary *dictionary = [receivedData objectFromJSONData];

        MadLog(@"Creating ad");
        self.currentAd = [[[MadvertiseAd alloc] initFromDictionary:dictionary] autorelease];

        // banner formats
        if (!self.currentAd.isMraid) {
            if (currentAdClass == MadvertiseAdClassMediumRectangle) {
                currentAd.width   = 300;
                currentAd.height  = 250;
            } else if (currentAdClass == MadvertiseAdClassMMA) {
                currentAd.width   = 320;
                currentAd.height  = 53;
            } else if (currentAdClass == MadvertiseAdClassLeaderboard){
                currentAd.width   = 728;
                currentAd.height  = 90;
            } else if (currentAdClass == MadvertiseAdClassFullscreen){
                currentAd.width   = 768;
                currentAd.height  = 768;
            } else if (currentAdClass == MadvertiseAdClassPortrait){
                currentAd.width   = 766;
                currentAd.height  = 66;
            } else if (currentAdClass == MadvertiseAdClassLandscape){
                currentAd.width   = 1024;
                currentAd.height  = 66;
            } else if (currentAdClass == MadvertiseAdClassRichMedia) {
                CGRect screen     = [[UIScreen mainScreen] bounds];
                currentAd.height  = screen.size.height;
                currentAd.width   =  screen.size.width;
                } 
            }
      
            [self displayView];
    } else if (!isExpanded) {
        // dispatch status notification
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseAdLoadFailed" object:[NSNumber numberWithInt:responseCode]];
    }

    self.request = nil;
    self.receivedData = nil;
}


// generate request, that is send to the ad server
- (void)loadAd {
  
  [self retain];

  [lock lock];

  if(self.request){
    MadLog(@"loadAd - returning because another request is running");
    [lock unlock];
    [self release];
    return;
  }

  NSString *server_url = @"http://ad.madvertise.de";
  if(madDelegate != nil && [madDelegate respondsToSelector:@selector(adServer)]) {
    server_url = [madDelegate adServer];
  }
  MadLog(@"Using url: %@",server_url);

  // always supported request parameter //
  if (madDelegate == nil || ![madDelegate respondsToSelector:@selector(appId)]) {
    MadLog(@"delegate does not respond to appId ! return ...");
    [self release];
    return;
  }

  ////////////////  POST PARAMS ////////////////
  NSMutableDictionary* post_params = [[NSMutableDictionary alloc] init];
  self.receivedData = [NSMutableData data];

  NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/site/%@", server_url, [madDelegate appId]]];
  MadLog(@"AppId : %@", [madDelegate appId]);

  //get application name
  NSString *appName = [MadvertiseUtilities getAppName];
  [post_params setValue:appName forKey:MADVERTISE_APP_NAME_KEY];
  MadLog(@"application name: %@", appName);

  NSString *appVersion = [MadvertiseUtilities getAppVersion];
  [post_params setValue:appVersion forKey:MADVERTISE_APP_VERSION_KEY];
  MadLog(@"application version: %@", appVersion);

  //get parent size
  CGSize parent_size =  [self getParentViewDimensions];
  [post_params setValue:[NSNumber numberWithFloat:parent_size.width] forKey:MADVERTISE_PARENT_WIDTH_KEY];
  [post_params setValue:[NSNumber numberWithFloat:parent_size.height] forKey:MADVERTISE_PARENT_HEIGHT_KEY];
  MadLog(@"parent size: %.f x %.f",parent_size.width, parent_size.height);

  //get screen size
  CGSize screen_size = [self getScreenResolution];
  [post_params setValue:[NSNumber numberWithFloat:screen_size.width] forKey:MADVERTISE_DEVICE_WIDTH_KEY];
  [post_params setValue:[NSNumber numberWithFloat:screen_size.height] forKey:MADVERTISE_DEVICE_HEIGHT_KEY];
  MadLog(@"screen size: %.f x %.f", screen_size.width, screen_size.height);

  //get screen orientation
  NSString* screen_orientation = [self getDeviceOrientation];
  [post_params setValue:screen_orientation forKey:MADVERTISE_ORIENTATION_KEY];
  MadLog(@"screen orientation: %@", screen_orientation);


  // optional url request parameter
  if ([madDelegate respondsToSelector:@selector(location)]) {
    CLLocationCoordinate2D location = [madDelegate location];
    [post_params setValue:[NSString stringWithFormat:@"%.6f", location.longitude] forKey:MADVERTISE_LNG_KEY];
    [post_params setValue:[NSString stringWithFormat:@"%.6f", location.latitude] forKey:MADVERTISE_LAT_KEY];
  }

  if ([madDelegate respondsToSelector:@selector(gender)]) {
    NSString *gender = [madDelegate gender];
    [post_params setValue:gender forKey:MADVERTISE_GENDER_KEY];
    MadLog(@"gender: %@", gender);
  }

  if ([madDelegate respondsToSelector:@selector(age)]) {
    NSString *age = [madDelegate age];
    [post_params setValue:age forKey:MADVERTISE_AGE_KEY];
    MadLog(@"%@", age);
  }

  MadLog(@"Init new request");
  self.request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:10.0];

  NSMutableDictionary* headers = [[NSMutableDictionary alloc] init];
  [headers setValue:@"application/x-www-form-urlencoded; charset=utf-8" forKey:@"Content-Type"];
  [headers setValue:@"application/vnd.madad+json; version=3" forKey:@"Accept"];

  MadLog(@"ua: %@", UserAgentString());

    // get IP
    NSString *ip = [MadvertiseUtilities getIP];
    MadLog(@"IP: %@", ip);

    [post_params setValue: @"true"                                    forKey:MADVERTISE_APP_KEY];
    [post_params setValue: [MadvertiseUtilities getDeviceIDHash]      forKey:MADVERTISE_DEVICE_ID_KEY];
    [post_params setValue: [UserAgentString() urlEncodeUsingEncoding:NSUTF8StringEncoding] forKey:MADVERTISE_USER_AGENT_KEY];
    [post_params setValue: ip                                         forKey:MADVERTISE_IP_KEY];
    [post_params setValue: @"json"                                    forKey:MADVERTISE_FORMAT_KEY];
    [post_params setValue: @"iPhone-SDK "                             forKey:MADVERTISE_REQUESTER_KEY];
    [post_params setValue: MADVERTISE_SDK_VERION                      forKey:MADVERTISE_SDK_VERION_KEY];
    [post_params setValue: [MadvertiseUtilities getTimestamp]         forKey:MADVERTISE_TIMESTAMP_KEY];
    [post_params setValue: MadvertiseAdClass_toString[currentAdClass] forKey:MADVERTISE_BANNER_TYPE_KEY];
    [post_params setValue: (([madDelegate respondsToSelector:@selector(debugEnabled)] && [madDelegate debugEnabled]) ? @"true" : @"false") forKey:MADVERTISE_DEBUG_KEY];
    [post_params setValue: @"true"                                      forKey:MADVERTISE_MRAID_KEY];

    NSString *body = @"";
    unsigned int n = 0;
    
    
    for (NSString* key in post_params) {
        body = [body stringByAppendingString:[NSString stringWithFormat:@"%@=%@", key, [post_params objectForKey:key]]];
        if (++n != [post_params count] ) {
            body = [body stringByAppendingString:@"&"];
        }
    }

    [request setHTTPMethod:@"POST"];
    [request setAllHTTPHeaderFields:headers];
    [request setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    MadLog(@"Sending request");

    self.conn = [[[NSURLConnection alloc] initWithRequest:request delegate:self] autorelease];
    MadLog(@"Request send");

    [headers release];
    [post_params release];
    [lock unlock];
    [self release];
}

- (void)openInSafariButtonPressed:(id)sender {
    MadLog(@"openInSafariButtonPressed called");
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:currentAd.clickUrl]];
}

- (void)stopTimer {
    if (self.timer && [timer isValid]) {
        [self.timer invalidate];
        self.timer = nil;
    }
}

- (void)createAdReloadTimer {
    // prepare automatic refresh
    if (interval > 0) {
        MadLog(@"Init Ad reload timer");
        [self stopTimer];
        self.timer = [NSTimer scheduledTimerWithTimeInterval: interval target: self selector: @selector(timerFired:) userInfo: nil repeats: YES];
    }
}

- (void)inAppBrowserClosed {
  if ([madDelegate respondsToSelector:@selector(inAppBrowserClosed)]) {
    [madDelegate inAppBrowserClosed];
  }
  [self createAdReloadTimer];
}


// ad has been touched, open click_url from he current app according to click_action
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
  //[super touchesBegan:touches withEvent:event];
  MadLog(@"touchesBegan");
  if (currentAd.shouldOpenInAppBrowser)
    [self openInAppBrowserWithUrl: currentAd.clickUrl];
  else
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:currentAd.clickUrl]];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
//  [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
//  [super touchesEnded:touches withEvent:event];
}


// Refreshing the ad
- (void)timerFired: (NSTimer *) theTimer {
  if (madDelegate != nil && [madDelegate respondsToSelector:@selector(appId)]) {
    MadLog(@"Ad reloading");
    [self loadAd];
  }
}

- (void)webViewDidFinishLoad:(UIWebView *)aWebView {
    if(aWebView != currentView) {
        [self swapView:aWebView oldView:currentView];
    }
}

- (void) displayView {
    MadLog(@"Display view");
    
    if (currentAd == nil) {
        MadLog(@"No ad to show");
        [self setUserInteractionEnabled:NO];
        return;
    }
    
    [self setUserInteractionEnabled:YES];

    self.frame = CGRectMake(x, y , currentAd.width, currentAd.height);
    UIWebView* view = nil;
    
    if ([currentAd isMraid]) {        
        MRAdView *mraidView = [[MRAdView alloc] initWithFrame:CGRectMake(0, 0, [currentAd width], [currentAd height]) 
                                                allowsExpansion:YES
                                                closeButtonStyle:MRAdViewCloseButtonStyleAdControlled
                                                placementType:placementType];
        mraidView.delegate = self; // TODO: set protocol
        [mraidView loadCreativeWithHTMLString:[currentAd to_html] baseURL:nil];
    }
    else {
        view = [[UIWebView alloc] initWithFrame:CGRectMake(0, 0 , currentAd.width, currentAd.height)];
        
        if (currentAdClass == MadvertiseAdClassRichMedia) {
            view.opaque = NO;
            view.backgroundColor = [UIColor clearColor];
            [view setUserInteractionEnabled:YES];
        } else {
            [view setUserInteractionEnabled:NO];
        }
        
        view.delegate = self;
        [view loadHTMLString:[currentAd to_html] baseURL:nil];
        
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseAdLoaded" object:[NSNumber numberWithInt:responseCode]];
    }
}


- (void)openInAppBrowserWithUrl: (NSString*)url {
  
  [self stopTimer];
  if ([madDelegate respondsToSelector:@selector(inAppBrowserWillOpen)]) {
    [madDelegate inAppBrowserWillOpen];
  }
  
    if (!self.inAppLandingPageController) {
        self.inAppLandingPageController = [[InAppLandingPageController alloc] init];
    }

  inAppLandingPageController.onClose =  @selector(inAppBrowserClosed);
  inAppLandingPageController.ad = currentAd;
  inAppLandingPageController.madvertise_view = self;
  inAppLandingPageController.url = url;
  
  // there isn't a rootViewController defined, try to find one
  if (!(self.rootViewController) && ([UIWindow instancesRespondToSelector:@selector(rootViewController)])) {
    self.rootViewController = [[[UIApplication sharedApplication] keyWindow] rootViewController];
  }
  
  if (self.rootViewController) {
    inAppLandingPageController.modalTransitionStyle = UIModalTransitionStyleFlipHorizontal;
    if (self.rootViewController.modalViewController) {
      [self.rootViewController.modalViewController presentModalViewController:inAppLandingPageController animated:YES];
    }
    else {
      [self.rootViewController presentModalViewController:inAppLandingPageController animated:YES];
    }
  }
  else {
    [inAppLandingPageController.view setFrame:[[UIScreen mainScreen] applicationFrame]];
    UIWindow *window = [[UIApplication sharedApplication] keyWindow];
    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationDuration:1.0];
    [UIView setAnimationTransition:UIViewAnimationTransitionFlipFromRight forView:window cache:YES];
    [window addSubview:inAppLandingPageController.view];
    [UIView commitAnimations];
  }
}

- (BOOL)webView:(UIWebView*)webView shouldStartLoadWithRequest:(NSURLRequest*)urlRequest navigationType:(UIWebViewNavigationType)navigationType {
  NSURL *url = [urlRequest URL];
  NSString *urlStr =   [url absoluteString];
  
  if ([urlStr isEqualToString:@"mad://close"]) { 
    [currentView removeFromSuperview];
    [self setUserInteractionEnabled:NO];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseRichMediaAdClosed" object:self];
  } else if([urlStr rangeOfString:@"inappbrowser"].location != NSNotFound) {
    [self openInAppBrowserWithUrl:urlStr];
  } else if([urlStr rangeOfString:@"exitapp"].location != NSNotFound) {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:urlStr]];
  }
  return YES;   
}

- (void)swapView:(UIWebView*)newView oldView:(UIWebView*) oldView {
  MadvertiseAnimationClass animationTyp;
  
  if ([madDelegate respondsToSelector:@selector(bannerAnimationTyp)]) {
    animationTyp = [madDelegate bannerAnimationTyp];
  } else {
    animationTyp = MadvertiseAnimationClassNone;
  }

    if (currentAdClass == MadvertiseAdClassRichMedia) {
        animationTyp = MadvertiseAnimationClassNone;
    }
    
    if (animationTyp == MadvertiseAnimationClassNone) {
      [self addSubview:newView];
      [self bringSubviewToFront:newView];
      [oldView removeFromSuperview];
      self.currentView = newView;
      return;
    }
  
  UIViewAnimationTransition transition = UIViewAnimationTransitionNone;
  
  float newStartAlpha = 1;
  float newEndAlpha = 1;
  float oldEndAlpha = 1;

  CGRect newStart = [newView frame];
  CGRect newEnd = [newView frame];
  CGRect oldEnd = [oldView frame];
  
  switch (animationTyp) {
    case MadvertiseAnimationClassLeftToRight:
      newStart.origin = CGPointMake(-newStart.size.width, newStart.origin.y);
      oldEnd.origin = CGPointMake(oldEnd.origin.x + oldEnd.size.width, oldEnd.origin.y);
      break;
    case MadvertiseAnimationClassTopToBottom:
      newStart.origin = CGPointMake(newStart.origin.x, -newStart.size.height);
      oldEnd.origin = CGPointMake(oldEnd.origin.x, oldEnd.origin.y + oldEnd.size.height);
      break;
    case MadvertiseAnimationClassCurlDown:
      transition = UIViewAnimationTransitionCurlDown;
      break;
    case MadvertiseAnimationClassNone:
      break;
    case MadvertiseAnimationClassFade:
      newStartAlpha = 0;
      newEndAlpha = 1;
      oldEndAlpha = 0;
      break;
    default:
      break;
  }
  
    newView.frame = newStart;
    newView.alpha = newStartAlpha;
  
    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationCurve:UIViewAnimationCurveEaseInOut];
    [UIView setAnimationDuration:animationDuration];
  
    if(transition) {
        [UIView setAnimationTransition:transition forView:self cache:YES];
    }
  
    newView.alpha = newEndAlpha;
    oldView.alpha = oldEndAlpha;
    newView.frame = newEnd;
    oldView.frame = oldEnd;
    [self addSubview:newView];
    [newView release];
 
    [UIView setAnimationDelegate:oldView];
    [UIView setAnimationDidStopSelector:@selector(removeFromSuperview)];
    [UIView commitAnimations];

    self.currentView.delegate = nil;
    
    if([self.currentView respondsToSelector:@selector(stopLoading)]) {
        [self.currentView stopLoading];
    }
    
    self.currentView = newView;
}

#pragma mark -
#pragma mark MRAdViewControllerDelegate

- (UIViewController *)viewControllerForPresentingModalView {
    for (UIView* next = [self superview]; next; next = next.superview) {
        UIResponder* nextResponder = [next nextResponder];
        if ([nextResponder isKindOfClass:[UIViewController class]]) {
            return (UIViewController*)nextResponder;
        }
    }
    return nil;
}

- (void)closeButtonPressed {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseMRaidAdClosed" object:nil];
}

- (void)adDidLoad:(MRAdView *)adView {
    [self swapView:adView oldView:currentView];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseMRaidAdDidLoad" object:adView];
    
    // madvertise notification stuff
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseAdLoaded" object:nil];
}

- (void)adDidFailToLoad:(MRAdView *)adView {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseMRaidAdDidFailToload" object:adView];
    
    // madvertise notification stuff
    MadLog(@"Failed to receive MRAID ad");
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseAdLoadFailed" object:[NSNumber numberWithInt:responseCode]];
}

- (void)appShouldSuspendForAd:(MRAdView *)adView {
    [self stopTimer];
    isExpanded = true;
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseMRaidAppShouldSuspend" object:adView];
}

- (void)appShouldResumeFromAd:(MRAdView *)adView {
    isExpanded = false;
    [self createAdReloadTimer];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseMRaidAppShouldResume" object:adView];
}

// Called just before the ad is displayed on-screen.
- (void)adWillShow:(MRAdView *)adView {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseMRaidAdWillShow" object:adView];
}

// Called just after the ad has been displayed on-screen.
- (void)adDidShow:(MRAdView *)adView {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseMRaidAdDidShow" object:adView];
}

// Called just before the ad is hidden.
- (void)adWillHide:(MRAdView *)adView {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseMRaidAdWillHide" object:adView];
}

// Called just after the ad has been hidden.
- (void)adDidHide:(MRAdView *)adView {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseMRaidAdDidHide" object:adView];
}

// Called just before the ad expands.
- (void)willExpandAd:(MRAdView *)adView toFrame:(CGRect)frame {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseMRaidAdWillExpand" object:adView];
}

// Called just after the ad has expanded.
- (void)didExpandAd:(MRAdView *)adView toFrame:(CGRect)frame {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseMRaidAdDidExpand" object:adView];
}

// Called just before the ad closes.
- (void)adWillClose:(MRAdView *)adView {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseMRaidAdWillClose" object:adView];
}

// Called just after the ad has closed.
- (void)adDidClose:(MRAdView *)adView {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseMRaidAdDidClose" object:adView];
}

- (void)ad:(MRAdView *)adView didRequestCustomCloseEnabled:(BOOL)enabled {
    if (enabled) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseMRaidAdDidRequestCustomClose" object:adView];
    }
    else {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MadvertiseMRaidAdDidNotRequestCustomClose" object:adView];
    }
}

//////////////////////////////////////////
// private methonds for internal use only
//////////////////////////////////////////
#pragma mark - private methods section
- (CGSize) getParentViewDimensions{

  if([self superview] != nil){
    UIView *parent = [self superview];
    return CGSizeMake(parent.frame.size.width, parent.frame.size.height);
  }
  return CGSizeMake(0, 0);
}

- (CGSize) getScreenResolution{
  CGRect screen     = [[UIScreen mainScreen] bounds];
  return CGSizeMake(screen.size.width, screen.size.height);
}

- (NSString*) getDeviceOrientation{
  UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
  if(UIDeviceOrientationIsLandscape(orientation)){
    return @"landscape";
  }else{
    return @"portrait";
  }
}

@end
