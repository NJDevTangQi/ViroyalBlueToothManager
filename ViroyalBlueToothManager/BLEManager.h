//
//  BLEManager.h
//
//  Created by 熊国锋 on 2018/2/5.
//  Copyright © 2018年 南京远御网络科技有限公司. All rights reserved.
//

#import <CoreBluetooth/CoreBluetooth.h>
#import <AVFoundation/AVFoundation.h>

typedef void (^CommonBlock)(BOOL success, NSDictionary * _Nullable info);

@class BLEManager;

@protocol BLEManagerDelegate < NSObject >

// 蓝牙硬件状态改变通知
- (void)bleManager:(BLEManager *)manager stateDidChange:(CBManagerState)state;

// 扫描状态改变通知
- (void)bleManager:(BLEManager *)manager scaningDidChange:(BOOL)scaning;

// 是否配对扫描到的这个设备
- (BOOL)bleManager:(BLEManager *)manager shouldConnectDevice:(NSString *)name advertisementData:(NSDictionary *)advertisementData;

// 设备连接成功
- (void)bleManager:(BLEManager *)manager didConnectedToDevice:(NSString *)name;

// 蓝牙设备断开连接
- (void)bleManager:(BLEManager *)manager deviceDidDisconnected:(NSString *)name;

@optional

// 开始连接设备
- (void)bleManager:(BLEManager *)manager startToConnectToDevice:(NSString *)name;

// 设备连接失败
- (void)bleManager:(BLEManager *)manager didFailedConnectingToDevice:(NSString *)name;

// 唤醒语音助手
- (void)bleManagerDeviceDidWakeup:(BLEManager *)manager;

// 音频通道切换
- (void)audioSessionChangeFrom:(AVAudioSessionRouteDescription *)preRoute to:(AVAudioSessionRouteDescription *)currentRoute;

@end

@interface BLEManager : NSObject

@property (nonatomic, weak) id<BLEManagerDelegate>  delegate;

@property (nonatomic, readonly) BOOL                powerOn;
@property (nonatomic, readonly) BOOL                scaning;            // 扫描中
@property (nonatomic, readonly) BOOL                connecting;         // 连接中
@property (nonatomic, readonly) BOOL                connected;          // 连接状态

@property (nonatomic, readonly) NSString            *deviceName;        // BLE 设备名称
@property (nonatomic, readonly) NSString            *currentRouteName;  // 为了获取蓝牙 Audio 设备名称
@property (nonatomic, assign)   BOOL                updating;

+ (instancetype)manager;

- (void)startScan;

- (void)stopScan;

- (void)disconnectCurrentDeviceAndBlackList:(BOOL)add;


/**
 * 设置BtNotify代理
 */
- (void)registerBtNotifyDelegate;
/*
 * 向蓝牙设备发送指令，所有的指令会按照先后顺序，逐条发送，指令处理完成后，会调用 completion
 @param string 指令内容，非空
 @completion 完成回调
 */
- (void)sendCommand:(NSString *)string
     withCompletion:(nullable CommonBlock)completion;

/*
 * 设置电台频率
 */

- (void)setRadioFrequency:(CGFloat)frequency
           withCompletion:(nullable CommonBlock)completion;

/*
 * 接听电话
 */

- (void)answerCallWithCompletion:(nullable CommonBlock)completion;

/*
 * 挂断电话
 */

- (void)rejectCallWithCompletion:(nullable CommonBlock)completion;

/*
 * 拨打电话
 */

- (void)makeCall:(NSString *)number
      completion:(nullable CommonBlock)completion;

/*
 * 语音互动开始
 */
- (void)voiceStartWithCompletion:(nullable CommonBlock)completion;

/*
 * 语音互动结束
 */
- (void)voiceEndedWithCompletion:(nullable CommonBlock)completion;

/*
 * 查询客户编码
 */
- (void)queryCustomerWithCompletion:(nullable CommonBlock)completion;

/*
 * 查询固件版本
 */
- (void)queryVersionWithCompletion:(nullable CommonBlock)completion;

/*
 * 查询固件 mac
 */
- (void)queryMacWithCompletion:(nullable CommonBlock)completion;

/*
 * 更新固件版本
 */

typedef void (^BleProgressBlock)(float progress);

- (void)startUpdate:(NSURL *)fileUrl
      progressBlock:(nullable BleProgressBlock)progressBlock
         completion:(nullable CommonBlock)completion;

@end
