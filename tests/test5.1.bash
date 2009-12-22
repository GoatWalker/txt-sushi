#!/bin/bash

# http://www.itl.nist.gov/div897/ctg/dm/sql_examples.htm

./test4.1.bash | tssql 'select * from `-` WHERE TEMP_C < 0 AND MONTH = 1 ORDER BY RAIN_C + 0'