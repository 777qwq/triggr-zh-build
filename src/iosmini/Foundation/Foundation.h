#pragma once
#include <objc/objc.h>
#include <objc/runtime.h>

typedef struct _NSRange { NSUInteger location; NSUInteger length; } NSRange;
static inline NSRange NSMakeRange(NSUInteger l, NSUInteger n) { NSRange r; r.location = l; r.length = n; return r; }
#ifndef NULL
#define NULL ((void *)0)
#endif
#define NSNotFound ((NSUInteger)0x7fffffffffffffffUL)
enum { NSOrderedAscending = -1, NSOrderedSame = 0, NSOrderedDescending = 1 };
enum { NSLiteralSearch = 2 };

@class NSArray, NSDictionary, NSString;

__attribute__((objc_root_class))
@interface NSObject { Class isa; }
+ (instancetype)alloc;
- (instancetype)init;
- (Class)class;
- (BOOL)isKindOfClass:(Class)c;
- (BOOL)respondsToSelector:(SEL)s;
- (id)copy;
- (id)performSelector:(SEL)s withObject:(id)o afterDelay:(double)d;
- (NSString *)description;
- (const char *)UTF8String;
@end

@interface NSString : NSObject
+ (instancetype)stringWithUTF8String:(const char *)s;
+ (instancetype)stringWithFormat:(NSString *)fmt, ...;
+ (instancetype)stringWithString:(NSString *)s;
- (NSUInteger)length;
- (unichar)characterAtIndex:(NSUInteger)i;
- (NSString *)substringFromIndex:(NSUInteger)i;
- (NSString *)substringToIndex:(NSUInteger)i;
- (NSString *)substringWithRange:(NSRange)r;
- (BOOL)hasPrefix:(NSString *)s;
- (BOOL)hasSuffix:(NSString *)s;
- (BOOL)isEqualToString:(NSString *)s;
- (BOOL)containsString:(NSString *)s;
- (NSString *)stringByAppendingString:(NSString *)s;
- (NSArray *)componentsSeparatedByString:(NSString *)sep;
- (NSRange)rangeOfString:(NSString *)s;
- (NSRange)rangeOfString:(NSString *)s options:(NSUInteger)o range:(NSRange)r;
- (NSString *)stringByTrimmingCharactersInSet:(id)set;
- (NSString *)stringByReplacingCharactersInRange:(NSRange)r withString:(NSString *)s;
- (NSString *)uppercaseString;
- (NSString *)lowercaseString;
- (id)copy;
@end

@interface NSCharacterSet : NSObject
+ (id)whitespaceAndNewlineCharacterSet;
@end

@interface NSMutableString : NSString
+ (instancetype)string;
- (void)appendString:(NSString *)s;
- (void)appendFormat:(NSString *)fmt, ...;
- (void)setString:(NSString *)s;
@end

@interface NSArray : NSObject
+ (instancetype)arrayWithObjects:(id)first, ...;
- (NSUInteger)count;
- (id)objectAtIndex:(NSUInteger)i;
- (BOOL)containsObject:(id)o;
- (NSArray *)sortedArrayUsingFunction:(NSInteger (*)(id, id, void *))f context:(void *)c;
- (id)copy;
@end

@interface NSMutableArray : NSArray
+ (instancetype)array;
- (void)addObject:(id)o;
- (void)sortUsingFunction:(NSInteger (*)(id, id, void *))f context:(void *)c;
@end

@interface NSDictionary : NSObject
- (id)objectForKey:(id)k;
- (NSUInteger)count;
- (NSArray *)allKeys;
- (id)copy;
@end

@interface NSMutableDictionary : NSDictionary
+ (instancetype)dictionary;
- (void)setObject:(id)o forKey:(id)k;
@end

@interface NSAttributedString : NSObject
- (NSString *)string;
- (NSUInteger)length;
- (NSDictionary *)attributesAtIndex:(NSUInteger)i effectiveRange:(NSRange *)r;
@end

@interface NSMutableAttributedString : NSAttributedString
- (instancetype)initWithString:(NSString *)s attributes:(NSDictionary *)a;
@end

@interface NSBundle : NSObject
+ (NSBundle *)mainBundle;
- (NSString *)bundleIdentifier;
@end

@interface NSUserDefaults : NSObject
+ (NSUserDefaults *)standardUserDefaults;
- (BOOL)boolForKey:(NSString *)k;
- (void)setBool:(BOOL)v forKey:(NSString *)k;
- (BOOL)synchronize;
@end

NSString *NSStringFromClass(Class c);
