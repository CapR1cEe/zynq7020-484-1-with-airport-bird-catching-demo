"""PWM state-machine checks with simulated sysfs only; no hardware writes."""
import json
from pathlib import Path
import time
from unittest import mock

import target_control


def require(condition,message):
    if not condition:raise AssertionError(message)


def rejected(call,message):
    try:call()
    except (ValueError,RuntimeError,OSError):return
    raise AssertionError(message)


def check_control():
    writes=[];fail=set();values={}
    class Sysfs:
        def __init__(self,name):self.name=name
        def resolve(self,strict=False):return self
        def is_dir(self):return True
        def __str__(self):return self.name
        def __hash__(self):return hash(self.name)
        def __eq__(self,other):return isinstance(other,Sysfs) and self.name==other.name
        def __truediv__(self,other):return Sysfs(self.name+'/'+other)
        def read_text(self):
            if self.name=='config':return json.dumps(config)
            return values.get(self.name,'20000000')
        def write_text(self,value):
            writes.append((self.name,value))
            if (self.name,value) in fail:raise OSError('injected '+self.name)
            values[self.name]=value
    config=dict(enabled=True,pan=dict(sysfs_path='/sys/devices/mock/pwm0',
        min_us=1000,center_us=1500,max_us=2000,direction=1,gain_us_per_second=300),
        tilt=dict(sysfs_path='/sys/devices/mock/pwm1',
        min_us=1000,center_us=1500,max_us=2000,direction=-1,gain_us_per_second=300))
    def create():
        with mock.patch.object(target_control,'Path',side_effect=Sysfs):
            return target_control.PanTilt('config')
    box={'xyxy':[150,90,190,120]}
    control=create()
    try:
        require(writes==[('/sys/devices/mock/pwm0/enable','0'),
                         ('/sys/devices/mock/pwm1/enable','0')],'Startup did not disarm both axes')
        writes.clear()
        result=control.update(box,(192,128))
        require(result['enabled'] and [n.rsplit('/',1)[1] for n,_ in writes]==
                ['duty_cycle','duty_cycle','enable','enable'],'Duty/enable arm ordering differs')
        require(result['pulse_us'][0]>1500 and result['pulse_us'][1]<1500,'Axis direction differs')
        require(max(abs(v-1500) for v in result['pulse_us'])<=10,'Rate limit exceeded')
        require(control.update(None,(192,128))['reason']=='target_lost' and
                not control.active and control.enabled,'Target loss latched permission off')
        require(control.update(box,(192,128))['enabled'],'Reacquisition failed to re-arm')
        # Deliberately stop calling update: the watchdog must act independently.
        deadline=time.monotonic()+1.5
        while control.active and time.monotonic()<deadline:time.sleep(.02)
        require(not control.active and control.enabled,'Independent watchdog did not disarm')
        require(all(values['/sys/devices/mock/pwm%d/enable'%i]=='0' for i in range(2)),
                'Watchdog left a channel enabled')
        require(control.update(box,(192,128))['enabled'],'Watchdog recovery failed')
        rejected(lambda:control.update({'xyxy':[float('nan'),0,4,4]},(192,128)),
                 'Non-finite target accepted')
        require(not control.active,'Invalid target did not disarm')
    finally:control.disable()
    require(not control.update(box,(192,128))['enabled'],'Final shutdown re-armed')
    checks=[dict(name='pwm_simulated_arm_loss_reacquire_watchdog_limits',physical_test=False)]
    for fail_write in ('duty_cycle','enable'):
        control=create();writes.clear()
        fail.add(('/sys/devices/mock/pwm1/'+fail_write,'1500000' if fail_write=='duty_cycle' else '1'))
        # Center target makes the staged duty exactly 1500000 ns.
        try:
            rejected(lambda:control.update({'xyxy':[80,48,112,80]},(192,128)),
                     'PWM I/O failure was hidden')
            require(control.fault is not None and not control.enabled and not control.active,
                    'PWM fault failed to latch closed')
            require(all(values['/sys/devices/mock/pwm%d/enable'%i]=='0' for i in range(2)),
                    'PWM failure left an axis on')
        finally:
            fail.clear();control.disable()
    control=create();writes.clear()
    fail.add(('/sys/devices/mock/pwm0/enable','0'))
    try:
        rejected(control.disable,'PWM disable failure was hidden')
        require(('/sys/devices/mock/pwm1/enable','0') in writes,'Second disable attempt was skipped')
    finally:fail.clear();control.disable()
    checks.append(dict(name='pwm_simulated_write_fault_and_dual_shutdown',physical_test=False))
    for change in ('period','gain','duplicate','path'):
        saved=json.loads(json.dumps(config))
        if change=='period':values['/sys/devices/mock/pwm1/period']='1000000'
        elif change=='gain':config['pan']['gain_us_per_second']=float('nan')
        elif change=='duplicate':config['tilt']['sysfs_path']=config['pan']['sysfs_path']
        else:config['pan']['sysfs_path']='/tmp/pwm'
        try:rejected(create,'Invalid PWM configuration accepted: '+change)
        finally:
            config=saved;values.pop('/sys/devices/mock/pwm1/period',None)
    checks.append(dict(name='pwm_config_validation',cases=4,physical_test=False))
    return checks
