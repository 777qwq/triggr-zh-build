#pragma once
#include <Foundation/Foundation.h>

typedef NSUInteger UIControlState;
enum { UIControlStateNormal = 0 };

@class UIWindow;

@interface UIResponder : NSObject
- (UIResponder *)nextResponder;
@end

@interface UIView : UIResponder
@property (readonly) NSArray *subviews;
- (UIView *)superview;
- (UIWindow *)window;
- (void)didMoveToWindow;
@end

@interface UIViewController : UIResponder
- (void)viewDidAppear:(BOOL)animated;
- (void)viewWillDisappear:(BOOL)animated;
- (UIView *)view;
- (NSString *)title;
- (void)setTitle:(NSString *)t;
- (void)presentViewController:(id)vc animated:(BOOL)a completion:(id)c;
@end

@interface UILabel : UIView
- (void)setText:(NSString *)t;
- (NSString *)text;
- (void)setAttributedText:(NSAttributedString *)t;
- (NSAttributedString *)attributedText;
@end

@interface UIButton : UIView
- (void)setTitle:(NSString *)t forState:(UIControlState)s;
- (NSString *)titleForState:(UIControlState)s;
- (void)setAttributedTitle:(NSAttributedString *)t forState:(UIControlState)s;
@end

@interface UINavigationItem : NSObject
- (void)setTitle:(NSString *)t;
@end

@interface UISegmentedControl : UIView
- (void)setTitle:(NSString *)t forSegmentAtIndex:(NSUInteger)i;
- (NSString *)titleForSegmentAtIndex:(NSUInteger)i;
- (NSUInteger)numberOfSegments;
@end

@interface UITextField : UIView
- (void)setText:(NSString *)t;
- (NSString *)text;
- (void)setPlaceholder:(NSString *)t;
@end

@interface UITextView : UIView
- (void)setText:(NSString *)t;
- (NSString *)text;
- (void)setAttributedText:(NSAttributedString *)t;
- (NSAttributedString *)attributedText;
@end

@interface UISearchBar : UIView
- (void)setPlaceholder:(NSString *)t;
@end

@interface UIBarButtonItem : NSObject
- (void)setTitle:(NSString *)t;
@end

@interface UITabBarItem : NSObject
- (void)setTitle:(NSString *)t;
@end

@interface UIAlertAction : NSObject
+ (instancetype)actionWithTitle:(NSString *)t style:(NSInteger)s handler:(id)h;
@end

@interface UIAlertController : UIViewController
+ (instancetype)alertControllerWithTitle:(NSString *)t message:(NSString *)m preferredStyle:(NSInteger)s;
- (void)addAction:(UIAlertAction *)a;
@end
