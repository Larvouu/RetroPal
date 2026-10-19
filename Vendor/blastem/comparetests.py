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
		
def is_sr_in_dreg(a, b):
	if not a.startswith('d'):
		return False
	if not b.startswith('d'):
		return False
	_,_,a = a.partition(' ')
	_,_,b = b.partition(' ')
	try:
		a = int(a.strip(), 16)
		b = int(b.strip(), 16)
	except:
		return False
	return (a & 0xFFE0) == 0x2700 and (b & 0xFFE0) == 0x2700 
	

def print_mismatch(path, b, m):
	blines = b.split('\n')
	mlines = m.split('\n')
	if len(blines) != len(mlines):
		print('-----------------------------')
		print('Unknown mismatch in', path)
		print('blastem output:')
		print(b)
		print('clean output:')
		print(m)
		print('-----------------------------')
		return
	prevline = ''
	differences = []
	flagmismatch = False
	regmismatch = False
	cyclemismatch = False
	for i in range(0, len(blines)):
		if blines[i] != mlines[i]:
			if prevline == 'XNZVC' or is_sr_in_dreg(blines[i], mlines[i]):
				differences.append((prevline, prevline))
				flagmismatch = True
			elif blines[i].startswith('cycles: ') and mlines[i].startswith('cycles: '):
				cyclemismatch = True
			else:
				regmismatch = True
			differences.append((blines[i], mlines[i]))
		prevline = blines[i]
	if (flagmismatch + regmismatch + cyclemismatch) > 1:
		mtype = 'General'
	elif flagmismatch:
		mtype = 'Flag'
	elif regmismatch:
		mtype = 'Register'
	elif cyclemismatch:
		mtype = 'Cycle'
	else:
		mtype = 'Unknown'
	print('-----------------------------')
	print(mtype, 'mismatch in', path)
	for i in range(0, 2):
		print('clean' if i else 'blastem', 'output:')
		for diff in differences:
			print(diff[i])
	print('-----------------------------')



for path in glob('generated_tests/*/*.bin'):
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
		b = subprocess.check_output(['./trans', path], timeout=5).decode('utf-8')
		try:
			m = subprocess.check_output(['../blastem_clean/trans', path], timeout=5).decode('utf-8')
			#_,_,b = b.partition('\n')
			if b != m:
				print_mismatch(path, b, m)

			else:
				print(path, 'passed')
		except subprocess.CalledProcessError as e:
			print('-----------------------------')
			print('clean exited with code', e.returncode, 'for test', path)
			print('blastem output:')
			print(b)
			print('-----------------------------')
		except subprocess.TimeoutExpired as e:
			print('-----------------------------')
			print('clean timed out ', e, ' for test', path)
			print('blastem output:')
			print(b)
			print('-----------------------------')
	except subprocess.CalledProcessError as e:
		print('-----------------------------')
		print('blastem exited with code', e.returncode, 'for test', path)
		print('-----------------------------')
	except subprocess.TimeoutExpired as e:
		print('-----------------------------')
		print('blastem timed out ', e, ' for test', path)
		print('-----------------------------')
