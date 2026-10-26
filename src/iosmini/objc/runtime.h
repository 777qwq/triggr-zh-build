#pragma once
#include <objc/objc.h>
typedef struct objc_selector *SEL;
typedef struct objc_method *Method;
typedef struct objc_class *Class;
Class objc_getClass(const char *name);
Method class_getInstanceMethod(Class cls, SEL name);
Method class_getClassMethod(Class cls, SEL name);
void method_exchangeImplementations(Method a, Method b);
SEL sel_registerName(const char *name);
