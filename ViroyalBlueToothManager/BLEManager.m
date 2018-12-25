//
//  BLEManager.m
//
//  Created by 熊国锋 on 2018/2/5.
//  Copyright © 2018年 南京远御网络科技有限公司. All rights reserved.
//

#import "BLEManager.h"
#import "BtNotify.h"

typedef enum : NSUInteger {
    BtCmdStateInit,         // 初始状态
    BtCmdStateSent,         // 已经发送
    BtCmdStateEcho,         // 收到回应
    BtCmdStateFailed,       // 处理完毕
    BtCmdStateFinished      // 处理完毕
} BtCmdState;

@interface BTCommand : NSObject

@property (nonatomic, copy) NSString        *cmdString;
@property (nonatomic, copy) NSString        *echoString;
@property (nonatomic, assign) BtCmdState    state;
@property (nonatomic, copy) CommonBlock     completion;
@property (nonatomic, copy) NSDate          *date;

@end

@implementation BTCommand

+ (instancetype)commandWithString:(NSString *)string completion:(CommonBlock)completion {
    return [[self alloc] initWithString:string completion:completion];
}

- (instancetype)initWithString:(NSString *)string completion:(CommonBlock)completion {
    if (self = [self init]) {
        self.cmdString = string;
        self.state = BtCmdStateInit;
        self.completion = completion;
    }
    
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@, state: %d", self.cmdString, self.state];
}

@end

@interface BLEManager () < CBCentralManagerDelegate, CBPeripheralDelegate, NotifyCustomDelegate, NotifyFotaDelegate >

@property (nonatomic, strong) CBCentralManager  *centralManager;
@property (nonatomic, strong) NSMutableArray    *peripherals;

@property (nonatomic, strong) CBPeripheral      *peripheral;
@property (nonatomic, strong) CBCharacteristic  *characteristic;
@property (nonatomic, strong) NSMutableArray    *arrCommand;
@property (nonatomic, assign) BOOL              connecting;
@property (nonatomic, assign) BOOL              connected;
@property (nonatomic, assign) BOOL              powerOn;

@property (nonatomic, strong) NSTimer           *connectTimer;

@property (nonatomic, strong) NSMutableArray    *blacklist;
@property (nonatomic, copy)   NSDate            *wakeupStart;

@property (nonatomic, strong) CBService         *dogpService;
@property (nonatomic, strong) CBCharacteristic  *dogpReadCharacteristic;
@property (nonatomic, strong) CBCharacteristic  *dogpWriteCharacteristic;
@property (nonatomic, copy)   BleProgressBlock  progressBlock;
@property (nonatomic, copy)   CommonBlock       completionBlock;
@property (nonatomic, assign) BOOL              updating;

@property (nonatomic, assign) BOOL              voiceStart;

@property (nonatomic, strong) NSTimer           *timer;

@end

@implementation BLEManager

+ (instancetype)manager {
    static dispatch_once_t onceToken;
    static BLEManager *client = nil;
    dispatch_once(&onceToken, ^{
        client = [BLEManager new];
    });
    
    return client;
}

- (instancetype)init {
    if (self = [super init]) {
        self.peripherals = [NSMutableArray new];
        
        self.centralManager = [[CBCentralManager alloc] initWithDelegate:self
                                                                   queue:nil
                                                                 options:@{CBCentralManagerOptionShowPowerAlertKey: @NO}];
        
        [self.centralManager addObserver:self
                              forKeyPath:@"isScanning"
                                 options:NSKeyValueObservingOptionNew
                                 context:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(audioSessionRouteChange:)
                                                     name:AVAudioSessionRouteChangeNotification
                                                   object:[AVAudioSession sharedInstance]];
    }
    
    return self;
}

- (BOOL)scaning {
    return self.centralManager.isScanning;
}

- (NSString *)deviceName {
    return self.connected?self.peripheral.name:nil;
}

- (NSString *)currentRouteName {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    AVAudioSessionPortDescription *port = session.currentRoute.outputs.firstObject;
    return port.portName;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"isScanning"]) {
        NSNumber *value = change[NSKeyValueChangeNewKey];
        BOOL scaning = [value boolValue];
        NSLog(@"BLE scaning: %@", scaning?@"ON":@"OFF");
        [self.delegate bleManager:self scaningDidChange:scaning];
    }
}

- (void)applicationDidEnterBackground:(NSNotification *)noti {
    [self.centralManager stopScan];
}

- (void)audioSessionRouteChange:(NSNotification *)noti {
    AVAudioSessionRouteDescription *preRoute = noti.userInfo[AVAudioSessionRouteChangePreviousRouteKey];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(audioSessionChangeFrom:to:)]) {
            [self.delegate audioSessionChangeFrom:preRoute to:[AVAudioSession sharedInstance].currentRoute];
        }
    });
}

- (void)startScan {
    if (self.connected) {
        // 已经连接
        return;
    }
    
    [self.centralManager scanForPeripheralsWithServices:nil
                                                options:nil];
}

- (void)stopScan {
    [self.centralManager stopScan];
}

- (void)disconnectCurrentDeviceAndBlackList:(BOOL)add {
    [self.centralManager cancelPeripheralConnection:self.peripheral];
    if (add) {
        if (!self.blacklist) {
            self.blacklist = [NSMutableArray new];
        }
        
        [self.blacklist addObject:self.peripheral.name];
    }
}

- (void)sendCommand:(NSString *)string withCompletion:(CommonBlock)completion {
    if (!self.connected) {
        if (completion) {
            completion(NO, @{@"error_msg" : @"蓝牙连接已断开"});
        }
        
        return;
    }
    
    if (self.updating) {
        if (completion) {
            completion(NO, @{@"error_msg" : @"固件更新中"});
        }
        
        return;
    }
    
    BTCommand *cmd = [BTCommand commandWithString:string completion:completion];
    [self.arrCommand addObject:cmd];
    
    [self nextCommand];
}

- (void)nextCommand {
    BTCommand *cmd = self.arrCommand.firstObject;
    if (cmd) {
        if (cmd.state == BtCmdStateInit) {
            [self sendString:cmd.cmdString];
            cmd.state = BtCmdStateSent;
            cmd.date = [NSDate date];
        }
        else if (cmd.state == BtCmdStateFinished) {
            [self.arrCommand removeObjectAtIndex:0];
            
            [self nextCommand];
        }
        else {
            if (cmd.state == BtCmdStateFailed || [[NSDate date] timeIntervalSinceDate:cmd.date] > 30) {
                // 发送失败或者超时，直接移除
                [self.arrCommand removeObjectAtIndex:0];
                if (cmd.completion) {
                    cmd.completion(NO, @{@"error_msg" : @"蓝牙连接已断开"});
                }
                
                [self nextCommand];
            }
        }
    }
}

- (void)sendString:(NSString *)string {
    [self writeString:string
           peripheral:self.peripheral
       characteristic:self.characteristic];
}

- (void)setRadioFrequency:(CGFloat)frequency
           withCompletion:(nullable CommonBlock)completion {
    NSString *string = [NSString stringWithFormat:@"AT+FMFREQ=%.0f", frequency * 10];
    [self sendCommand:string
       withCompletion:completion];
}

- (void)answerCallWithCompletion:(nullable CommonBlock)completion {
    [self sendCommand:@"AT+CALLANSW"
       withCompletion:completion];
}

- (void)rejectCallWithCompletion:(nullable CommonBlock)completion {
    [self sendCommand:@"AT+CALLEND"
       withCompletion:completion];
}

- (void)makeCall:(NSString *)number
      completion:(nullable CommonBlock)completion {
    [self sendCommand:[NSString stringWithFormat:@"AT+DIAL=%@", number]
    withCompletion:completion];
}

- (void)voiceStartWithCompletion:(CommonBlock)completion {
    if (self.voiceStart) {
        return;
    }
    
    self.voiceStart = YES;
    [self sendCommand:@"AT+VOICESTART"
       withCompletion:completion];
}

- (void)voiceEndedWithCompletion:(CommonBlock)completion {
    self.voiceStart = NO;
    [self sendCommand:@"AT+VOICESTOP"
       withCompletion:completion];
}

- (void)queryCustomerWithCompletion:(CommonBlock)completion {
    [self sendCommand:@"AT+CUSTOMER"
       withCompletion:completion];
}

- (void)queryVersionWithCompletion:(CommonBlock)completion {
    [self sendCommand:@"AT+VERSION"
       withCompletion:completion];
}

- (void)queryMacWithCompletion:(CommonBlock)completion {
    [self sendCommand:@"AT+BTMAC"
       withCompletion:completion];
}

- (void)startUpdate:(NSURL *)fileUrl
      progressBlock:(BleProgressBlock)progressBlock
         completion:(CommonBlock)completion {
    
#if !TARGET_IPHONE_SIMULATOR
    if (![[BtNotify sharedInstance] isReadyToSend]) {
        if (completion) {
            completion(NO, @{@"msg": @"尚未准备好，请稍后再试"});
        }
        return;
    }
    
    [[BtNotify sharedInstance] registerFotaDelegate:self];
    [[BtNotify sharedInstance] registerCustomDelegate:self];
    
    self.progressBlock = progressBlock;
    self.completionBlock = completion;
    
    NSData *data = [NSData dataWithContentsOfURL:fileUrl];
    if (data.length == 0) {
        if (completion) {
            completion(NO, @{@"msg": @"文件错误"});
        }
        return;
    }
    
    [[BtNotify sharedInstance] sendFotaData:FBIN_FOTA_UPDATE firmwareData:data];
    self.updating = YES;
#endif //
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    switch (central.state) {
        case CBManagerStatePoweredOn:
            
            break;
            
        default:
            break;
    }
    
    self.powerOn = central.state == CBManagerStatePoweredOn;
    
    // 硬件电源状态改变，连接全部失效
    self.peripheral = nil;
    self.connected = NO;
    
    [self.delegate bleManager:self stateDidChange:central.state];
}

- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary<NSString *,id> *)advertisementData RSSI:(NSNumber *)RSSI {
    NSString *name = peripheral.name;
    [self.peripherals addObject:peripheral];
    
    if (name && [self.blacklist containsObject:name]) {
        // 在黑名单中，不能要
        return;
    }
    
    if ([name length] > 0
        && !self.connected
        && [self.delegate respondsToSelector:@selector(bleManager:shouldConnectDevice:advertisementData:)]
        && [self.delegate bleManager:self shouldConnectDevice:name advertisementData:advertisementData]) {
        
        NSLog(@"BLE didDiscoverPeripheral: %@", peripheral);
        
        // 连接之前，先终止扫描
        [central stopScan];
        
        self.connecting = YES;
        [central connectPeripheral:peripheral options:nil];
        
        [self startConnectTimer];
        
        if ([self.delegate respondsToSelector:@selector(bleManager:startToConnectToDevice:)]) {
            [self.delegate bleManager:self startToConnectToDevice:peripheral.name];
        }
    }
}

- (void)startConnectTimer {
    [self stopConnectTimer];
    
    self.connectTimer = [NSTimer scheduledTimerWithTimeInterval:1.1
                                                         target:self
                                                       selector:@selector(connectTimerFire:)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)stopConnectTimer {
    if ([self.connectTimer isValid]) {
        [self.connectTimer invalidate];
    }
}

- (void)connectTimerFire:(NSTimer *)timer {
    CBPeripheral *peripheral = [self.centralManager retrieveConnectedPeripheralsWithServices:@[[CBUUID UUIDWithString:@"18A0"], [CBUUID UUIDWithString:@"FF10"]]].firstObject;
    if (!self.connected && peripheral.state == CBPeripheralStateConnected) {
        // 目前已经有连上的设备
        [timer invalidate];
        
        CBService *service = peripheral.services.firstObject;
        for (CBService *item in peripheral.services) {
            [self peripheral:peripheral didConnectService:item];
        }
    }
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if ([self.delegate respondsToSelector:@selector(bleManager:didFailedConnectingToDevice:)]) {
        [self.delegate bleManager:self didFailedConnectingToDevice:peripheral.name];
    }
    
    self.connecting = NO;
    
    [self startScan];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    NSLog(@"BLE didConnectPeripheral: %@", peripheral.name);
    
    self.connecting = NO;
    [self stopConnectTimer];
    self.peripheral = peripheral;
    
    peripheral.delegate = self;
    [peripheral discoverServices:nil];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    NSLog(@"BLE didDisconnectPeripheral: %@", peripheral.name);
    
    self.connecting = NO;
    self.connected = NO;
    self.updating = NO;
    
    if (self.completionBlock) {
        self.completionBlock(NO, @{@"msg": @"异常中断"});
    }
    
    if (self.peripheral == peripheral) {
        self.peripheral = nil;
        
        [self.delegate bleManager:self deviceDidDisconnected:peripheral.name];
    }
    
    [self startScan];
}

#pragma mark - CBPeripheralDelegate

- (void)peripheralDidUpdateName:(CBPeripheral *)peripheral {
    
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    for (CBService *item in peripheral.services) {
        [peripheral discoverCharacteristics:nil forService:item];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didConnectService:(CBService *)service {
    NSString *string = service.UUID.UUIDString;
    if ([string isEqualToString:@"18A0"]) {
        // FOTA service
        self.dogpService = service;
        for (CBCharacteristic *item in service.characteristics) {
            if (item.properties & CBCharacteristicPropertyRead) {
                self.dogpReadCharacteristic = item;
            }
            else if (item.properties & CBCharacteristicPropertyWrite) {
                self.dogpWriteCharacteristic = item;
            }
            else {
                NSAssert(NO, @"You should not be here!");
            }
        }
        
        if (self.dogpReadCharacteristic && self.dogpWriteCharacteristic) {
#if !TARGET_IPHONE_SIMULATOR
            [[BtNotify sharedInstance] setGattParameters:peripheral writeCharacteristic:self.dogpWriteCharacteristic readCharacteristic:self.dogpReadCharacteristic];
            [[BtNotify sharedInstance] updateConnectionState:CBPeripheralStateConnected];
#endif //
        }
    }
    else if ([string isEqualToString:@"FF10"]) {
        // AT 命令 service
        CBCharacteristic *characteristic = service.characteristics.firstObject;
        
        self.characteristic = characteristic;
        self.arrCommand = [NSMutableArray new];
        
        self.connected = self.centralManager.state == CBManagerStatePoweredOn && self.peripheral && self.characteristic;
        
        [peripheral setNotifyValue:YES forCharacteristic:characteristic];
        [self.delegate bleManager:self didConnectedToDevice:peripheral.name];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    [self peripheral:peripheral didConnectService:service];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    [peripheral readValueForCharacteristic:characteristic];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (characteristic == self.dogpReadCharacteristic) {
#if !TARGET_IPHONE_SIMULATOR
        [[BtNotify sharedInstance] handleReadReceivedData:characteristic error:error];
#endif //
    }
    else if (characteristic == self.dogpWriteCharacteristic) {
        // no handle
    }
    else {
        NSString *value = [[NSString alloc] initWithData:characteristic.value encoding:NSUTF8StringEncoding];
        value = [value stringByReplacingOccurrencesOfString:@"\r\n" withString:@" "];
        
        if (self.updating) {
            NSLog(@"固件更新中，忽略 AT 命令");
            return;
        }
        
        NSArray *arr = [value componentsSeparatedByString:@" "];
        for (NSString *item in arr) {
            if (item.length == 0) {
                continue;
            }
            
            NSLog(@"BLE >> %@", item);
            BOOL processed = NO;
            for (BTCommand *cmd in self.arrCommand) {
                switch (cmd.state) {
                    case BtCmdStateInit: {
                        
                    }
                        break;
                        
                    case BtCmdStateSent: {
                        /*
                         * 下发指令是这样 AT+FMFREQ=969
                         * 收到回应是这样 +FMFREQ:969
                         * 此处需要将两者匹配
                         */
                        
                        NSString *tmp = item;
                        NSRange range = [tmp rangeOfString:@":"];
                        if (range.length > 0) {
                            tmp = [tmp substringToIndex:range.location];
                        }
                        
                        if ([cmd.cmdString containsString:tmp]) {
                            cmd.state = BtCmdStateEcho;
                            cmd.echoString = item;
                            processed = YES;
                        }
                    }
                        
                        break;
                        
                    case BtCmdStateEcho: {
                        if ([item isEqualToString:@"OK"]) {
                            cmd.state = BtCmdStateFinished;
                            if (cmd.completion) {
                                cmd.completion(YES, @{@"response" : cmd.echoString?:item});
                            }
                            
                            processed = YES;
                        }
                    }
                        
                        break;
                        
                    default:
                        break;
                }
                
                if (processed) {
                    break;
                }
            }
            
            if (!processed) {
                // 没有处理，可能是主动上报的命令
                if ([item containsString:@"AT+WAKEUP"]) {
                    self.wakeupStart = [NSDate new];
                    
                    self.timer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:NO block:^(NSTimer * _Nonnull timer) {
                        if ([self.delegate respondsToSelector:@selector(bleManagerDeviceDidWakeup:)]) {
                            [self.delegate bleManagerDeviceDidWakeup:self];
                        }
                    }];
                    [[NSRunLoop currentRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
                }
                else if ([item containsString:@"AT+PSERSORFAR"] && self.wakeupStart) {
                    if (self.timer) {
                        [self.timer invalidate];
                        self.timer = nil;
                    }
                    
                    self.wakeupStart = nil;
                    
//                    NSTimeInterval interval = [[NSDate new] timeIntervalSinceDate:self.wakeupStart];
//                    if (interval > 2.0) {
//                        // 间隔超过2秒，才会被当做是手势唤醒
//                        if ([self.delegate respondsToSelector:@selector(bleManagerDeviceDidWakeup:)]) {
//                            [self.delegate bleManagerDeviceDidWakeup:self];
//                        }
//                    }
                    
                }
            }
        }
        
        [self nextCommand];
    }
}

- (void)writeString:(NSString *)string
         peripheral:(CBPeripheral *)peripheral
     characteristic:(CBCharacteristic *)characteristic {
    
    NSLog(@"BLE << %@", string);
    [self writeData:[string dataUsingEncoding:NSUTF8StringEncoding]
         peripheral:peripheral
     characteristic:characteristic];
}

- (void)writeData:(NSData *)data
       peripheral:(CBPeripheral *)peripheral
   characteristic:(CBCharacteristic *)characteristic {
    [peripheral writeValue:data
         forCharacteristic:characteristic
                      type:CBCharacteristicWriteWithResponse];
    
    [peripheral setNotifyValue:YES forCharacteristic:characteristic];
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (characteristic == self.dogpReadCharacteristic) {
        // no handle
    }
    else if (characteristic == self.dogpWriteCharacteristic) {
#if !TARGET_IPHONE_SIMULATOR
        [[BtNotify sharedInstance] handleWriteResponse:characteristic error:error];
#endif //
    }
    else {
        [self nextCommand];
    }
}

#pragma mark - NotifyCustomDelegate, NotifyFotaDelegate

-(void)onReadyToSend:(BOOL)ready {
    NSLog(@"%s", __PRETTY_FUNCTION__);
}

-(void)onDataArrival:(NSString *)receiver arrivalData:(NSData *)data {
    NSLog(@"%s", __PRETTY_FUNCTION__);
}

-(void)onProgress:(NSString *)sender
      newProgress:(float)progress {
    NSLog(@"%s", __PRETTY_FUNCTION__);
}

-(void)onFotaVersionReceived:(FotaVersion *)version {
    NSLog(@"%s", __PRETTY_FUNCTION__);
}

-(void)onFotaTypeReceived:(int)fotaType {
    NSLog(@"%s", __PRETTY_FUNCTION__);
}

-(void)onFotaStatusReceived:(int)status {
    self.updating = NO;
    if (self.completionBlock) {
        BOOL success = status == FOTA_UPDATE_VIA_BT_TRANSFER_SUCCESS;
        self.completionBlock(success, @{@"msg": success?@"更新成功，请将支架断电重启":@"更新失败，请稍后再试"});
        self.completionBlock = nil;
    }
}

-(void)onFotaProgress:(float)progress {
    if (self.progressBlock) {
        self.progressBlock(progress);
    }
}

@end
