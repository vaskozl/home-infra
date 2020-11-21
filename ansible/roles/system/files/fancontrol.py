#!/usr/bin/env python3

from gpiozero import PWMOutputDevice
import time

TARGET_TEMP = 60 # (degrees Celsius)
MAX_DIFF = 10

SLEEP_INTERVAL = 0.5  # (seconds) How often we check the core temperature.
GPIO_PIN = 18  # (Only 12, 13, 18 and 19 are PWM pins)

K_p = 0.0
K_i = 0.1
K_d = 0.0

def get_temp():
    return int(open("/sys/class/thermal/thermal_zone0/temp").read())/1000.0

if __name__ == '__main__':
    # Validate the on and off thresholds
    fan = PWMOutputDevice(GPIO_PIN, initial_value=1.0, frequency=100)
    fan.on()

    err_i = 0
    last_err = 0
    while True:
        temp = get_temp()

        # Get an error between 0.0 and 1.0
        err = (temp - TARGET_TEMP)/MAX_DIFF
        err = max(-1.0,min(err,1.0))

        # Keep track of integral and derivative
        err_i += err
        err_i = max(0,min(err_i, 1/K_i))
        err_d = err - last_err
        last_err = err

        duty = K_p * err + K_d * err_d + K_i * err_i
        duty = max(0.0,min(duty,1.0))
        # Duty cycles less than 10% don't spin up the fan at all
        if duty < 0.10:
            duty = 0.0

        # Convert err to a duty cycle between 0.0 and 1.0
        fan.value = duty
        #print("Current temp is %.2fC | PWM: %.2f" % (temp, duty))
        #print("err: %.2f, integral: %.2f" % (err, err_i))
        time.sleep(1.0)
