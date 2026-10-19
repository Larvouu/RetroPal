#!/usr/bin/env python3
from glob import glob
import subprocess
from sys import exit,argv

prefixes = []
skip = set()
for i in range(1, len(argv)):
	if '.' in argv[i]:
		f = open(argv[i])
		for line in f:
			parts = line.split()
			for part in parts:
				if part.endswith('.bin'):
					skip.add(part)
		f.close()
		print('Skipping',len(skip),'entries from previous report.')
	else:
		prefixes.append(argv[i])

for path in glob('ztests/*/*.bin'):
	if path in skip:
		continue
	if prefixes:
		good = False
		fname = path.split('/')[-1]
		for prefix in prefixes:
			if fname.startswith(prefix):
				good = True
				break
		if not good:
			continue
	try:
		b = subprocess.check_output(['./ztestrun', path]).decode()
		try:
			m = subprocess.check_output(['../blastem_clean/ztestrun', path]).decode()
			#_,_,b = b.partition('\n')
			m = m.split('\n')
			b = b.split('\n')
			if b != m:
				lastWasFlags = False
				bdiff = []
				mdiff = []
				for i in range(0, max(len(b), len(m))):
					bl = b[i] if i < len(b) else ''
					ml = m[i] if i < len(m) else ''
					if bl != ml:
						if lastWasFlags:
							bdiff.append(b[i - 1])
							mdiff.append(m[i - 1])
						bdiff.append(bl)
						mdiff.append(ml)
					lastWasFlags =  bl.startswith('Flags: ')
				print('-----------------------------')
				print('Mismatch in ' + path)
				print('blastem output:')
				for b in bdiff:
					print(b)
				print('clean output:')
				for m in mdiff:
					print(m)
				print('-----------------------------')
			else:
				print(path, 'passed')
		except subprocess.CalledProcessError as e:
			print('-----------------------------')
			print('clean exited with code', e.returncode, 'for test', path)
			print('blastem output:')
			print(b)
			print('-----------------------------')
	except subprocess.CalledProcessError as e:
		print('-----------------------------')
		print('blastem exited with code', e.returncode, 'for test', path)
		print('-----------------------------')

