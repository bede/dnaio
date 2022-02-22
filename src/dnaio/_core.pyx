# cython: language_level=3, emit_code_comments=False

from cpython.buffer cimport PyBUF_SIMPLE, PyObject_GetBuffer, PyBuffer_Release
from cpython.bytes cimport PyBytes_FromStringAndSize, PyBytes_AS_STRING, PyBytes_Check, PyBytes_GET_SIZE, PyBytes_CheckExact
from cpython.mem cimport PyMem_Free, PyMem_Malloc, PyMem_Realloc
from cpython.unicode cimport PyUnicode_DecodeLatin1, PyUnicode_Check, PyUnicode_GET_LENGTH
from cpython.ref cimport PyObject
from libc.string cimport strncmp, memcmp, memcpy, memchr, strcspn, memmove
cimport cython

cdef extern from "Python.h":
    unsigned char * PyUnicode_1BYTE_DATA(object o)
    int PyUnicode_KIND(object o)
    int PyUnicode_1BYTE_KIND
    object PyUnicode_New(Py_ssize_t size, Py_UCS4 maxchar)

from typing import Union

from .exceptions import FastqFormatError
from ._util import shorten


cdef class Sequence:
    """
    A sequencing read with read name/id and (optional) qualities

    If qualities are available, they are as
    For a Sequence a FASTA file
    record containing a read in a FASTA or FASTQ file. For FASTA, the qualities attribute
    is None. For FASTQ, qualities is a string and it contains the qualities
    encoded as ASCII(qual+33).

    Attributes:
      name (str): The read description
      sequence (str):
      qualities (str):
    """
    cdef:
        public str name
        public str sequence
        public str qualities

    def __cinit__(self, str name, str sequence, str qualities=None):
        """Set qualities to None if there are no quality values"""
        self.name = name
        self.sequence = sequence
        self.qualities = qualities

    def __init__(self, str name, str sequence, str qualities = None):
        # __cinit__ is called first and sets all the variables.
        if qualities is not None and len(qualities) != len(sequence):
            rname = shorten(name)
            raise ValueError("In read named {!r}: length of quality sequence "
                             "({}) and length of read ({}) do not match".format(
                rname, len(qualities), len(sequence)))

    def __getitem__(self, key):
        """
        Slice this Sequence. If the qualities attribute is not None, it is
        sliced accordingly. The read name is copied unchanged.

        Returns:
          A new Sequence object with a sliced sequence.
        """
        return self.__class__(
            self.name,
            self.sequence[key],
            self.qualities[key] if self.qualities is not None else None)

    def __repr__(self):
        qstr = ''
        if self.qualities is not None:
            qstr = ', qualities={!r}'.format(shorten(self.qualities))
        return '<Sequence(name={!r}, sequence={!r}{})>'.format(
            shorten(self.name), shorten(self.sequence), qstr)

    def __len__(self):
        """
        Returns:
           The number of characters in this sequence
        """
        return len(self.sequence)

    def __richcmp__(self, other, int op):
        if 2 <= op <= 3:
            eq = self.name == other.name and \
                self.sequence == other.sequence and \
                self.qualities == other.qualities
            if op == 2:
                return eq
            else:
                return not eq
        else:
            raise NotImplementedError()

    def __reduce__(self):
        return (Sequence, (self.name, self.sequence, self.qualities))

    def qualities_as_bytes(self):
        """Return the qualities as a bytes object.

        This is a faster version of qualities.encode('ascii')."""
        return self.qualities.encode('ascii')

    def fastq_bytes(self, two_headers = False):
        """Return the entire FASTQ record as bytes which can be written
        into a file.

        Optionally the header (after the @) can be repeated on the third line
        (after the +), when two_headers is enabled."""
        cdef:
            char * name
            char * sequence
            char * qualities
            Py_ssize_t name_length
            Py_ssize_t sequence_length
            Py_ssize_t qualities_length

        if PyUnicode_KIND(self.name) == PyUnicode_1BYTE_KIND:
            name = <char *>PyUnicode_1BYTE_DATA(self.name)
            name_length = <size_t>PyUnicode_GET_LENGTH(self.name)
        else:
            # Allow non-ASCII in name
            name_bytes = self.name.encode('latin-1')
            name = PyBytes_AS_STRING(name_bytes)
            name_length = PyBytes_GET_SIZE(name_bytes)
        if PyUnicode_KIND(self.sequence) == PyUnicode_1BYTE_KIND:
            sequence = <char *>PyUnicode_1BYTE_DATA(self.sequence)
            sequence_length = <size_t>PyUnicode_GET_LENGTH(self.sequence)
        else:
            # Don't allow non-ASCII in sequence and qualities
            sequence_bytes = self.sequence.encode('ascii')
            sequence = PyBytes_AS_STRING(sequence_bytes)
            sequence_length = PyBytes_GET_SIZE(sequence_bytes)
        if PyUnicode_KIND(self.qualities) == PyUnicode_1BYTE_KIND:
            qualities = <char *>PyUnicode_1BYTE_DATA(self.qualities)
            qualities_length = <size_t>PyUnicode_GET_LENGTH(self.qualities)
        else:
            qualities_bytes = self.qualities.encode('ascii')
            qualities = PyBytes_AS_STRING(qualities_bytes)
            qualities_length = PyBytes_GET_SIZE(qualities_bytes)
        return create_fastq_record(name, sequence, qualities,
                                   name_length, sequence_length, qualities_length,
                                   two_headers)

    def fastq_bytes_two_headers(self):
        """
        Return this record in FASTQ format as a bytes object where the header (after the @) is
        repeated on the third line.
        """
        return self.fastq_bytes(two_headers=True)

    def is_mate(self, Sequence other):
        """Check whether this instance and other are part of the same read pair

        Checking is done by comparing IDs. The ID is the part of the name
        before the first whitespace. Any 1,2 or 3 at the end of the IDs is
        excluded from the check as forward reads may have a 1 appended to their
        ID and reverse reads a 2 etc.

        Args:
            other (Sequence): The Sequence object to compare.

        Returns:
            bool: Whether this and other are part of the same read pair.
        """
        cdef:
            char * header1_chars = NULL
            char * header2_chars = NULL
            size_t header1_length
        # No need to check if type is unicode as it is guaranteed by the type.
        if PyUnicode_KIND(self.name) == PyUnicode_1BYTE_KIND:
            header1_chars = <char *>PyUnicode_1BYTE_DATA(self.name)
            header1_length = <size_t> PyUnicode_GET_LENGTH(self.name)
        else:
            raise ValueError(f"name should be ASCII-only. Got {self.name!r}.")

        if PyUnicode_KIND(other.name) == PyUnicode_1BYTE_KIND:
            header2_chars = <char *>PyUnicode_1BYTE_DATA(other.name)
        else:
            raise ValueError(f"name should be ASCII-only. Got {other.name!r}.")
        return record_ids_match(header1_chars, header2_chars, header1_length)


cdef class BytesSequence:
    cdef:
        public bytes name
        public bytes sequence
        public bytes qualities

    def __cinit__(self, bytes name, bytes sequence, bytes qualities):
        """Set qualities to None if there are no quality values"""
        self.name = name
        self.sequence = sequence
        self.qualities = qualities

    def __init__(self, bytes name, bytes sequence, bytes qualities):
        # __cinit__ is called first and sets all the variables.
        if len(qualities) != len(sequence):
            rname = shorten(name)
            raise ValueError("In read named {!r}: length of quality sequence "
                             "({}) and length of read ({}) do not match".format(
                rname, len(qualities), len(sequence)))
    
    def __repr__(self):
        return '<BytesSequence(name={!r}, sequence={!r}, qualities={!r})>'.format(
            shorten(self.name), shorten(self.sequence), shorten(self.qualities))

    def __len__(self):
        """
        Returns:
           The number of characters in this sequence
        """
        return len(self.sequence)

    def __richcmp__(self, other, int op):
        if 2 <= op <= 3:
            eq = self.name == other.name and \
                self.sequence == other.sequence and \
                self.qualities == other.qualities
            if op == 2:
                return eq
            else:
                return not eq
        else:
            raise NotImplementedError()

    def fastq_bytes(self, two_headers=False):
        name = PyBytes_AS_STRING(self.name)
        name_length = PyBytes_GET_SIZE(self.name)
        sequence = PyBytes_AS_STRING(self.sequence)
        sequence_length = PyBytes_GET_SIZE(self.sequence)
        qualities = PyBytes_AS_STRING(self.qualities)
        qualities_length = PyBytes_GET_SIZE(self.qualities)
        return create_fastq_record(name, sequence, qualities,
                                   name_length, sequence_length, qualities_length,
                                   two_headers)

    def fastq_bytes_two_headers(self):
        """
        Return this record in FASTQ format as a bytes object where the header (after the @) is
        repeated on the third line.
        """
        return self.fastq_bytes(two_headers=True)

    def is_mate(self, BytesSequence other):
        """Check whether this instance and other are part of the same read pair

        Checking is done by comparing IDs. The ID is the part of the name
        before the first whitespace. Any 1,2 or 3 at the end of the IDs is
        excluded from the check as forward reads may have a 1 appended to their
        ID and reverse reads a 2 etc.

        Args:
            other (BytesSequence): The BytesSequence object to compare.

        Returns:
            bool: Whether this and other are part of the same read pair.
        """
        # No need to check if type is bytes as it is guaranteed by the type.
        return record_ids_match(PyBytes_AS_STRING(self.name),
                                PyBytes_AS_STRING(other.name),
                                PyBytes_GET_SIZE(self.name))


cdef bytes create_fastq_record(char * name, char * sequence, char * qualities,
                               Py_ssize_t name_length,
                               Py_ssize_t sequence_length,
                               Py_ssize_t qualities_length,
                               bint two_headers = False):
        # Total size is name + sequence + qualities + 4 newlines + '+' and an
        # '@' to be put in front of the name.
        cdef Py_ssize_t total_size = name_length + sequence_length + qualities_length + 6

        if two_headers:
            # We need space for the name after the +.
            total_size += name_length

        # This is the canonical way to create an uninitialized bytestring of given size
        cdef bytes retval = PyBytes_FromStringAndSize(NULL, total_size)
        cdef char * retval_ptr = PyBytes_AS_STRING(retval)

        # Write the sequences into the bytestring at the correct positions.
        cdef size_t cursor
        retval_ptr[0] = b"@"
        memcpy(retval_ptr + 1, name, name_length)
        cursor = name_length + 1
        retval_ptr[cursor] = b"\n"; cursor += 1
        memcpy(retval_ptr + cursor, sequence, sequence_length)
        cursor += sequence_length
        retval_ptr[cursor] = b"\n"; cursor += 1
        retval_ptr[cursor] = b"+"; cursor += 1
        if two_headers:
            memcpy(retval_ptr + cursor, name, name_length)
            cursor += name_length
        retval_ptr[cursor] = b"\n"; cursor += 1
        memcpy(retval_ptr + cursor, qualities, qualities_length)
        cursor += qualities_length
        retval_ptr[cursor] = b"\n"
        return retval


def paired_fastq_heads(buf1, buf2, Py_ssize_t end1, Py_ssize_t end2):
    """
    Skip forward in the two buffers by multiples of four lines.

    Return a tuple (length1, length2) such that buf1[:length1] and
    buf2[:length2] contain the same number of lines (where the
    line number is divisible by four).
    """
    # Acquire buffers. Cython automatically checks for errors here.
    cdef Py_buffer data1_buffer
    cdef Py_buffer data2_buffer
    PyObject_GetBuffer(buf1, &data1_buffer, PyBUF_SIMPLE)
    PyObject_GetBuffer(buf2, &data2_buffer, PyBUF_SIMPLE)

    cdef:
        Py_ssize_t linebreaks = 0
        char * data1 = <char *>data1_buffer.buf
        char * data2 = <char *>data2_buffer.buf
        # The min() function ensures we do not read beyond the size of the buffer.
        char * data1_end = data1 + min(end1, data1_buffer.len)
        char * data2_end = data2 + min(end2, data2_buffer.len)
        char * pos1 = data1
        char * pos2 = data2
        char * record_start1 = data1
        char * record_start2 = data2

    while True:
        pos1 = <char *>memchr(pos1, b'\n', data1_end - pos1)
        if pos1 == NULL:
            break
        pos1 += 1
        pos2 = <char *>memchr(pos2, b'\n', data2_end - pos2)
        if pos2 == NULL:
            break
        pos2 += 1
        linebreaks += 1
        if linebreaks == 4:
            linebreaks = 0
            record_start1 = pos1
            record_start2 = pos2

    # Hit the end of the data block
    # This code will always be reached, so the buffers are always safely released.
    PyBuffer_Release(&data1_buffer)
    PyBuffer_Release(&data2_buffer)
    return record_start1 - data1, record_start2 - data2


cdef class FastqIter:
    """
    Parse a FASTQ file and yield Sequence objects

    The *first value* that the generator yields is a boolean indicating whether
    the first record in the FASTQ has a repeated header (in the third row
    after the ``+``).

    file -- a file-like object, opened in binary mode (it must have a readinto
    method)

    buffer_size -- size of the initial buffer. This is automatically grown
        if a FASTQ record is encountered that does not fit.
    """
    cdef:
        Py_ssize_t buffer_size
        char *buffer
        Py_ssize_t bytes_in_buffer
        type sequence_class
        bint save_as_bytes
        bint use_custom_class
        bint extra_newline
        bint yielded_two_headers
        bint eof
        object file
        Py_ssize_t record_start
    cdef readonly Py_ssize_t number_of_records

    def __cinit__(self, file, sequence_class, Py_ssize_t buffer_size):
        self.buffer_size = buffer_size
        self.buffer = <char *>PyMem_Malloc(self.buffer_size)
        if self.buffer == NULL:
            raise MemoryError()
        self.bytes_in_buffer = 0
        self.sequence_class = sequence_class
        self.save_as_bytes = sequence_class is BytesSequence
        self.use_custom_class = (sequence_class is not Sequence and
                                 sequence_class is not BytesSequence)
        self.number_of_records = 0
        self.extra_newline = False
        self.yielded_two_headers = False
        self.eof = False
        self.record_start = 0
        self.file = file
        if buffer_size < 1:
            raise ValueError("Starting buffer size too small")

    def __dealloc__(self):
        PyMem_Free(self.buffer)

    cdef _read_into_buffer(self):
        # This function sets self.record_start at 0 and makes sure self.buffer
        # starts at the start of a FASTQ record. Any incomplete FASTQ remainder
        # of the already processed buffer is moved to the start of the buffer
        # and the rest of the buffer is filled up with bytes from the file.

        cdef char *tmp
        cdef Py_ssize_t remaining_bytes

        if self.record_start == 0 and self.bytes_in_buffer == self.buffer_size:
            # buffer too small, double it
            self.buffer_size *= 2
            tmp = <char *>PyMem_Realloc(self.buffer, self.buffer_size)
            if tmp == NULL:
                raise MemoryError()
            self.buffer = tmp
        else:
            # Move the incomplete record from the end of the buffer to the beginning.
            remaining_bytes = self.bytes_in_buffer - self.record_start
            # Memmove copies safely when dest and src overlap.
            memmove(self.buffer, self.buffer + self.record_start, remaining_bytes)
            self.bytes_in_buffer = remaining_bytes
            self.record_start = 0

        cdef Py_ssize_t empty_bytes_in_buffer = self.buffer_size - self.bytes_in_buffer
        cdef object filechunk = self.file.read(empty_bytes_in_buffer)
        if not PyBytes_CheckExact(filechunk):
            raise TypeError("self.file is not a binary file reader.")
        cdef Py_ssize_t filechunk_size = PyBytes_GET_SIZE(filechunk)
        if filechunk_size > empty_bytes_in_buffer:
            raise ValueError(f"read() returned too much data: "
                             f"{empty_bytes_in_buffer} bytes requested, "
                             f"{filechunk_size} bytes returned.")
        memcpy(self.buffer + self.bytes_in_buffer, PyBytes_AS_STRING(filechunk), filechunk_size)
        self.bytes_in_buffer += filechunk_size

        if filechunk_size == 0:  # End of file
            if self.bytes_in_buffer == 0:  # EOF Reached. Stop iterating.
                self.eof = True
            elif not self.extra_newline and self.buffer[self.bytes_in_buffer - 1] != b'\n':
                # There is still data in the buffer and its last character is
                # not a newline: This is a file that is missing the final
                # newline. Append a newline and continue.
                self.buffer[self.bytes_in_buffer] = b'\n'
                self.bytes_in_buffer += 1
                self.extra_newline = True
            else:  # Incomplete FASTQ records are present.
                if self.extra_newline:
                    # Do not report the linefeed that was added by dnaio but
                    # was not present in the original input.
                    self.bytes_in_buffer -= 1
                lines = self.buffer[self.record_start:self.bytes_in_buffer].count(b'\n')
                raise FastqFormatError(
                    'Premature end of file encountered. The incomplete final record was: '
                    '{!r}'.format(
                        shorten(self.buffer[self.record_start:self.bytes_in_buffer].decode('latin-1'),
                                500)),
                    line=self.number_of_records * 4 + lines)

    def __iter__(self):
        return self

    def __next__(self):
        cdef:
            object ret_val
            Py_ssize_t name_start, name_end, name_length
            Py_ssize_t sequence_start, sequence_end, sequence_length
            Py_ssize_t second_header_start, second_header_end, second_header_length
            Py_ssize_t qualities_start, qualities_end, qualities_length
            char *name_end_ptr
            char *sequence_end_ptr
            char *second_header_end_ptr
            char *qualities_end_ptr
        # Repeatedly attempt to parse the buffer until we have found a full record.
        # If an attempt fails, we read more data before retrying.
        while True:
            if self.eof:
                raise StopIteration()
            ### Check for a complete record (i.e 4 newlines are present)
            # Use libc memchr, this optimizes looking for characters by
            # using 64-bit integers. See:
            # https://sourceware.org/git/?p=glibc.git;a=blob_plain;f=string/memchr.c;hb=HEAD
            # void *memchr(const void *str, int c, size_t n)
            name_end_ptr = <char *>memchr(self.buffer + self.record_start, b'\n', <size_t>(self.bytes_in_buffer - self.record_start))
            if name_end_ptr == NULL:
                self._read_into_buffer()
                continue
            # self.bytes_in_buffer - sequence_start is always nonnegative:
            # - name_end is at most self.bytes_in_buffer - 1
            # - thus sequence_start is at most self.bytes_in_buffer
            name_end = name_end_ptr - self.buffer
            sequence_start = name_end + 1
            sequence_end_ptr = <char *>memchr(self.buffer + sequence_start, b'\n', <size_t>(self.bytes_in_buffer - sequence_start))
            if sequence_end_ptr == NULL:
                self._read_into_buffer()
                continue
            sequence_end = sequence_end_ptr - self.buffer
            second_header_start = sequence_end + 1
            second_header_end_ptr = <char *>memchr(self.buffer + second_header_start, b'\n', <size_t>(self.bytes_in_buffer - second_header_start))
            if second_header_end_ptr == NULL:
                self._read_into_buffer()
                continue
            second_header_end = second_header_end_ptr - self.buffer
            qualities_start = second_header_end + 1
            qualities_end_ptr = <char *>memchr(self.buffer + qualities_start, b'\n', <size_t>(self.bytes_in_buffer - qualities_start))
            if qualities_end_ptr == NULL:
                self._read_into_buffer()
                continue
            qualities_end = qualities_end_ptr - self.buffer

            if self.buffer[self.record_start] != b'@':
                raise FastqFormatError("Line expected to "
                    "start with '@', but found {!r}".format(chr(self.buffer[self.record_start])),
                    line=self.number_of_records * 4)
            if self.buffer[second_header_start] != b'+':
                raise FastqFormatError("Line expected to "
                    "start with '+', but found {!r}".format(chr(self.buffer[second_header_start])),
                    line=self.number_of_records * 4 + 2)

            name_start = self.record_start + 1  # Skip @
            second_header_start += 1  # Skip +
            name_length = name_end - name_start
            sequence_length = sequence_end - sequence_start
            second_header_length = second_header_end - second_header_start
            qualities_length = qualities_end - qualities_start

            # Check for \r\n line-endings and compensate
            if self.buffer[name_end - 1] == b'\r':
                name_length -= 1
            if self.buffer[sequence_end - 1] == b'\r':
                sequence_length -= 1
            if self.buffer[second_header_end - 1] == b'\r':
                second_header_length -= 1
            if self.buffer[qualities_end - 1] == b'\r':
                qualities_length -= 1

            if second_header_length:  # should be 0 when only + is present
                if (name_length != second_header_length or
                        strncmp(self.buffer+second_header_start,
                            self.buffer + name_start, second_header_length) != 0):
                    raise FastqFormatError(
                        "Sequence descriptions don't match ('{}' != '{}').\n"
                        "The second sequence description must be either "
                        "empty or equal to the first description.".format(
                            self.buffer[name_start:name_end].decode('latin-1'),
                            self.buffer[second_header_start:second_header_end]
                            .decode('latin-1')), line=self.number_of_records * 4 + 2)

            if qualities_length != sequence_length:
                raise FastqFormatError(
                    "Length of sequence and qualities differ", line=self.number_of_records * 4 + 3)

            if self.number_of_records == 0 and not self.yielded_two_headers:
                self.yielded_two_headers = True
                return bool(second_header_length)  # first yielded value is special

            if self.save_as_bytes:
                name = PyBytes_FromStringAndSize(self.buffer + name_start, name_length)
                sequence = PyBytes_FromStringAndSize(self.buffer + sequence_start, sequence_length)
                qualities = PyBytes_FromStringAndSize(self.buffer + qualities_start, qualities_length)
                ret_val = BytesSequence.__new__(BytesSequence, name, sequence, qualities)
            else:
                # Constructing objects with PyUnicode_New and memcpy bypasses some of
                # the checks otherwise done when using PyUnicode_DecodeLatin1 or similar
                name = PyUnicode_New(name_length, 255)
                sequence = PyUnicode_New(sequence_length, 255)
                qualities = PyUnicode_New(qualities_length, 255)
                if <PyObject*>name == NULL or <PyObject*>sequence == NULL or <PyObject*>qualities == NULL:
                    raise MemoryError()
                memcpy(PyUnicode_1BYTE_DATA(name), self.buffer + name_start, name_length)
                memcpy(PyUnicode_1BYTE_DATA(sequence), self.buffer + sequence_start, sequence_length)
                memcpy(PyUnicode_1BYTE_DATA(qualities), self.buffer + qualities_start, qualities_length)
                
                if self.use_custom_class:
                    ret_val = self.sequence_class(name, sequence, qualities)
                else:
                    ret_val = Sequence.__new__(Sequence, name, sequence, qualities)

            ### Advance record to next position
            self.number_of_records += 1
            self.record_start = qualities_end + 1
            return ret_val


def record_names_match(header1: str, header2: str):
    """
    Check whether the sequence record ids id1 and id2 are compatible, ignoring a
    suffix of '1', '2' or '3'. This exception allows to check some old
    paired-end reads that have IDs ending in '/1' and '/2'. Also, the
    fastq-dump tool (used for converting SRA files to FASTQ) appends '.1', '.2'
    and sometimes '.3' to paired-end reads if option -I is used.
    """
    cdef:
        char * header1_chars = NULL
        char * header2_chars = NULL
        size_t header1_length
    if PyUnicode_Check(header1):
        if PyUnicode_KIND(header1) == PyUnicode_1BYTE_KIND:
            header1_chars = <char *>PyUnicode_1BYTE_DATA(header1)
            header1_length = <size_t> PyUnicode_GET_LENGTH(header1)
        else:
            header1 = header1.encode('latin1')
            header1_chars = PyBytes_AS_STRING(header1)
            header1_length = PyBytes_GET_SIZE(header1)
    else:
        raise TypeError(f"Header 1 is the wrong type. Expected bytes or string, "
                        f"got: {type(header1)}")

    if PyUnicode_Check(header2):
        if PyUnicode_KIND(header2) == PyUnicode_1BYTE_KIND:
            header2_chars = <char *>PyUnicode_1BYTE_DATA(header2)
        else:
            header2 = header2.encode('latin1')
            header2_chars = PyBytes_AS_STRING(header2)
    else:
        raise TypeError(f"Header 2 is the wrong type. Expected bytes or string, "
                        f"got: {type(header2)}")

    return record_ids_match(header1_chars, header2_chars, header1_length)


def record_names_match_bytes(header1: bytes, header2: bytes):
    if not (PyBytes_Check(header1) and PyBytes_Check(header2)):
        raise TypeError("Header1 and header2 should both be bytes objects. "
                        "Got {} and {}".format(type(header1), type(header2)))
    return record_ids_match(PyBytes_AS_STRING(header1),
                            PyBytes_AS_STRING(header2),
                            PyBytes_GET_SIZE(header1))

cdef bint record_ids_match(char *header1, char *header2, size_t header1_length):
    """
    Check whether the ASCII-encoded IDs match. Only header1_length is needed.
    """
    # Only the read ID is of interest.
    # Find the first tab or space, if not present, strcspn will return the
    # position of the terminating NULL byte. (I.e. the length).
    # Header1 is not searched because we can reuse the end of ID position of
    # header2 as header1's ID should end at the same position.
    cdef size_t id2_length = strcspn(header2, b' \t')

    if header1_length < id2_length:
        return False

    cdef char end = header1[id2_length]
    if end != b'\000' and end != b' ' and end != b'\t':
        return False

    # Check if the IDs end with 1, 2 or 3. This is the read pair number
    # which should not be included in the comparison.
    cdef bint id1endswithnumber = b'1' <= header1[id2_length - 1] <= b'3'
    cdef bint id2endswithnumber = b'1' <= header2[id2_length - 1] <= b'3'
    if id1endswithnumber and id2endswithnumber:
        id2_length -= 1

    # Compare the strings up to the ID end position.
    return memcmp(<void *>header1, <void *>header2, id2_length) == 0
