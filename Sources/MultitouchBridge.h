#ifndef MultitouchBridge_h
#define MultitouchBridge_h

#import <Foundation/Foundation.h>

// Reverse-engineered layout of Apple's private MultitouchSupport.framework.
// This shape has been stable across macOS releases for over a decade and is
// the same one used by tools like BetterTouchTool, Mac Mouse Fix, and MiddleDrag.

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier, state, unused1, unused2;
    MTVector normalized;
    float size;
    int32_t unused3;
    float angle, majorAxis, minorAxis;
    MTVector unused4;
    int32_t unused5, unused6;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef device, MTTouch *data, int32_t numFingers, double timestamp, int32_t frame);

extern MTDeviceRef MTDeviceCreateDefault(void);
extern void MTRegisterContactFrameCallback(MTDeviceRef device, MTContactCallbackFunction callback);
extern void MTUnregisterContactFrameCallback(MTDeviceRef device, MTContactCallbackFunction callback);
extern void MTDeviceStart(MTDeviceRef device, int32_t mode);
extern void MTDeviceStop(MTDeviceRef device);

#endif
