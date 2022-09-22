;*******************************************************************************
; Autore: Tommaso Fava
; Revisione: 14 Settembre 2022
;
; Specifiche:
; 
; - Si realizzi un firmware che conti quante volte un pulsante (RB0) viene premuto,
;   ed ogni 4 secondi scriva su porta seriale (EUSART) il totale di pressioni fino 
;   a quel momento, sotto forma di numero a due cifre decimali.
;
; - Modalità sleep quando possibile.
;  
; - Eventi gestiti tramite Interrupt.
    
	list		p=16f887	; tipo di processore
	#include	<p16f887.inc>	; file che contiene le definizioni
	
; Configurazione:
; - watchdog timer disattivato (_WDT_OFF) --> non necessario
; - low voltage programming disattivato (_LVP_OFF) --> possibile usare RB3 come I/O generico
; - altre configurazioni standard come da esempi
	
    	__CONFIG _CONFIG1, _INTRC_OSC_NOCLKOUT & _CP_OFF & _WDT_OFF & _BOR_OFF & _PWRTE_OFF & _LVP_OFF & _DEBUG_OFF & _CPD_OFF
	
; Definizione costanti 
tmr_10ms	EQU		(.256 - .39)	; valore iniziale del timer che gestisce debouncing
	
; Definizione variabili (16 byte in RAM condivisa, non serve selezionare banco)
			UDATA_SHR
	
; Variabili utilizzate per salvare lo stato della CPU all'ingresso dell'ISR	
w_temp  	RES		1
status_temp	RES		1	
pclath_temp	RES		1		
	
; Variabile usata per memorizzare lo stato del conteggio delle pressioni		
counter		RES		1
		
; Variabili usate per la trasmissione
buffer		RES		3
tx_count	RES		1
		
; Variabili usate per la conversione da binario a decimale	
tmp		RES		1
tmp2		RES		1
		
; Flag che indica quando la CPU può andare in sleep (solo i bit 0 e 1 sono utilizzati)		
canSleep	RES		1
	
; Vettore di reset
RST_VECTOR	CODE	0x0000
		
		pagesel	start	; imposta la pagina della memoria di programma in cui si trova l'indirizzo della label start
		goto	start	; salta all'indirizzo indicato dalla label start

;************************************** Programma principale ***********************************************		
MAIN		CODE
start
		; inizializzazione hardware
		pagesel INIT_HW
		call    INIT_HW
		
		; inizializzazione contatore
		clrf	counter	; clrf f: 00h --> f
		
		; inizializzazione led (RD0 spento)		
		banksel	PORTD			
		clrf	PORTD
		
		; attivazione Timer1: inizio conteggio 4 secondi
		banksel	T1CON
		bsf	T1CON, TMR1ON
		
		; abilitazione interrupt Timer1
		banksel PIE1
		bsf	PIE1, TMR1IE	
		
		; abilitazione interrupt delle periferiche aggiuntive (Timer1 e USART)
		bsf	INTCON, PEIE
		
		; abilitazione interrupt globali
		bsf	INTCON, GIE
		
		; la CPU può andare in sleep
		bsf	canSleep, 0	; sleep in base a debouncing
		bsf	canSleep, 1	; sleep in base a trasmissione
		
; Il loop non fa altro che controllare se il micro può andare in sleep. Il resto è gestito dalla ISR
main_loop       
waitSleep
		bcf	INTCON, GIE	; disabilita interrupt globalmente perchè non voglio interrupt ora							
		btfss	canSleep, 0	; controlla se sleep possibile o debouncing in corso
		goto	keepWait
		btfsc	canSleep, 1	; controlla se sleep possibile o trasmissione in corso
		goto	goSleep
keepWait		
		bsf	INTCON, GIE     ; riabilita interrupt per andare nell'ISR, perchè
		                        ; con GIE=0 e un interrupt il micro si sveglia ma non va alla routine
		goto	waitSleep
goSleep			
		sleep			; la CPU si ferma
		bsf	INTCON, GIE	; entrata nella ISR al risveglio
		goto	main_loop	; ripete il loop principale del programma

;************************************** Subroutine definite ***************************************
		
; inizializzazione hardware
INIT_HW   
	        ; Registro OPTION_REG (Timer0):
		; - pull-up porta B abilitati.
		; - interrupt su falling edge
		; - TMR0 incrementato da clock interno (1 MHz)
		; - prescaler assegnato a TMR0
		; - valore prescaler 1:256 (clock TMR0 = 3.90625 kHz)
		; Le impostazioni precedenti determinano per TMR0 i seguenti valori:
		;  - periodo di un singolo incremento (tick) = 256 us
		;  - periodo totale (da 00 a FF) = 65.536 ms
		banksel OPTION_REG		
		movlw	B'00000111'		
		movwf	OPTION_REG		
	
		; Registro INTCON (no banksel perchè stesso banco di OPTION_REG):
		clrf	INTCON		; tutti gli interrupt inizialmente disabilitati
		bsf	INTCON, INTE	; abilita interrupt su RB0/INT,
					; in questo modo RB0 può solo ricevere interruzioni esterne
					
		; Porte I/O (0 = out, 1 = in):
		banksel	TRISB			
		movlw	0x01		; RB0 settato come input
		movwf	TRISB					
		clrf	TRISD		; RD0 settato come output			
		
		; Pin digitali invece che analogici
		banksel ANSELH			
		clrf	ANSELH		; AN8..AN13 disattivati
					   
		; Timer1:
		; - usa quarzo esterno a f = 32.768 Hz
		; - modalità asincrona
		; - prescaler impostato a 1:2
		; - con il prescaler T_tick = 61.035 us
		; - T_max = 4s, corrisponde esattamente all'intervallo da contare 
		banksel	T1CON
		movlw	B'00011110'     ; TMR1 OFF, attivato dopo
		movwf	T1CON
		
		; USART:
		; - comunicazione asincrona
		; - baud rate = 19200
		; - trasmissione abilitata
		; - porta seriale abilitata
		banksel TXSTA
		movlw	B'00100100'
		movwf	TXSTA
		banksel RCSTA
		bsf	RCSTA, SPEN
		banksel BAUDCTL
		clrf	BAUDCTL		
		banksel SPBRG
		movlw	.12		; per baud rate desiderato (19.2k) in base a tabella su datasheet
		movwf	SPBRG
		
		return	

; Conversione da binario ad ASCII e stampa su porta seriale
BinToDec
		movf counter, w	   ;  copia counter in w
		movwf tmp	   ;  copia w in tmp (ora tmp = counter)
		clrf tmp2          ;  tmp2 parte da 0
		
loop_div
		movlw .10
		subwf tmp, w	   ; w = tmp - 10
		btfss STATUS, C	   ; se risultato negativo (C=0) fine
		goto end_div
		movwf tmp	   ; tmp = tmp - 10
		incf  tmp2, f	   ; incrementa decine (tmp2)
		goto loop_div
end_div
		; adesso tmp2 contiene le decine e tmp le unità
		movlw '0'	   ; sommo il codice ASCII di '0' per avere quello del numero che voglio
		addwf tmp2, w
		movwf buffer	   ; decine
		movlw '0'
		addwf tmp, w
		movwf (buffer+1)   ; unità
		movlw .10
		movwf (buffer+2)   ; newline
		
		return

; Attesa di tempo configurabile (in questo caso intero periodo)
DELAY
		banksel	TMR0
		clrf	TMR0		; timer parte da 0 (T = 65ms)
		bcf	INTCON, T0IF	; azzera il flag di overflow di TMR0
wait_delay	clrwdt			; azzera timer watchdog per evitare reset
		btfss	INTCON, T0IF	; se il flag di overflow del timer è = 1 salta l'istruzione seguente
		goto	wait_delay	; ripeti il loop di attesa
			
		return			
			
;************************************** ISR *******************************************************	
IRQ		CODE	0x0004
INTERRUPT
		; Salvataggio stato registri CPU (context saving).
		movwf	w_temp			
		swapf	STATUS, w	; inverte i nibble di STATUS salvando il risultato in W.
					; questo trucco permette di copiare STATUS senza alterarlo
		movwf	status_temp	; copia con i nibble invertiti,
					; situazione risolta con nuova swapf al ripristino		
		movf	PCLATH, w						
		movwf	pclath_temp
		
test_button
		; testa evento di falling edge su RB0
		btfss	INTCON, INTF
		goto	test_t0
		btfss	INTCON, INTE
		goto	test_t0
		; avvenuta pressione pulsante 
		bcf	INTCON, INTF	; azzera flag interrupt RB0
		; gestione contatore delle pressioni del pulsante
		incf	counter, 1	; incremento con risultato dentro 'counter'
		movlw	.100	
		subwf	counter, w	; confronto con valore 100
		btfsc	STATUS, Z	; controllo risultato sottrazione e salto se counter < 100 (C=0)	
		clrf	counter		; conteggio riparte da 0
		; inizio conteggio debouncing
		bcf	INTCON, INTE	; disabilita interrupt RB0 durante debouncing (possibili pressioni involontarie)
		banksel	TMR0
		movlw	tmr_10ms	; carica valore iniziale per il contatore di timer0
		movwf	TMR0
		bcf	INTCON, T0IF	; azzera flag interrupt di timer0
		bsf	INTCON, T0IE	; abilita interrupt di timer0
		; sleep vietato fino a termine debouncing (Timer0 dipende da clock interno)
		bcf	canSleep, 0	
		; fine evento pressione
		goto	irq_end	
		
test_t0
		; verifica che l'interrupt sia stato causato da timer0
		btfss	INTCON, T0IF		 
		goto 	test_t1		
		btfss	INTCON, T0IE            
		goto	test_t1
		; avvenuto interrupt timer0: termine debouncing
		bsf	INTCON, INTE    ; riabilita interrupt RB0 (disabilitato per durata debouncing)
		bcf	INTCON, T0IF	; azzera flag interrupt timer
		bcf	INTCON, T0IE	; disabilita interrupt timer (abilitato alla prossima pressione)
		; sleep di nuovo possibile
		bsf	canSleep, 0
		; fine evento Timer0
		goto	irq_end
		
test_t1
		; testa evento overflow timer1 
		banksel	PIE1
		btfss	PIE1, TMR1IE
		goto	test_usart
		banksel	PIR1
		btfss	PIR1, TMR1IF
		goto	test_usart
		; avvenuto interrupt timer1
		bcf	PIR1, TMR1IF	; azzera flag interrupt di timer1
		; accensione led di feedback
		banksel PORTD
		bsf	PORTD, 0	; primo led acceso
		; convertsione in decimale e salvataggio del risultato per trasmissione
		call	BinToDec	; chiama subroutine di conversione
		movlw	buffer		; copia in w l'indirizzo (literal!) di buffer
		movwf   FSR		; copia w nell'FSR per l'indirizzamento indiretto
		movlw	.3  
		movwf	tx_count	; copia '3' in tx_count per indicare byte residui
		; inizio scrittura seriale
		banksel PIE1
		bsf	PIE1, TXIE	; abilito interrupt trasmissione USART che parte subito
					; perchè TXIF sempre alto
		; fine evento Timer1
		goto	irq_end
			
test_usart		
		; testa evento di fine trasmissione
		banksel PIE1
		btfss	PIE1, TXIE
		goto	irq_end
		banksel PIR1
		btfss   PIR1, TXIF
		goto	irq_end
		; avvenuto interrupt di trasmissione seriale
		bcf	canSleep, 1	; sleep non possibile per inizio trasmissione
		movf	tx_count, w	; Se tx_count = 0 il bit Z di status = 0
		btfsc	STATUS, Z	; verifica se i byte da trasmettere sono terminati
		goto	tx_end
		; byte da inviare
		movf    INDF, w		; INDF contiene il dato all'indirizzo dentro FSR (che è quello di buffer)		    
		banksel TXREG
		movwf	TXREG		; riempie il buffer di trasmissione e la inizia
		incf    FSR		; incrementa il puntatore al buffer dei dati
		decf    tx_count, 1	; decrementa contatore byte mancanti
		goto	irq_end

tx_end
		; disabilito l'interrupt per non rientrarci continuamente
		banksel PIE1
		bcf	PIE1, TXIE
		; e spengo il led di feedback dopo una breve attesa
		pagesel DELAY   
		call	DELAY
		bcf	INTCON, T0IF	; era stato settato dentro DELAY
		banksel PORTD
		bcf	PORTD, 0	; led spento
		bsf	canSleep, 1	; sleep possibile per fine trasmissione
		; fine evento trasmissione
		goto	irq_end

irq_end
		movf	pclath_temp, w		 
		movwf	PCLATH		
		swapf	status_temp, w	; inverte i nibble ripristinando situazione iniziale				 
		movwf	STATUS			 
		; per ripristinare W senza alterare STATUS appena ripristinato si utilizza sempre swapf
		swapf	w_temp, f	; prima inversione di w_temp, risultato su se stesso
		swapf	w_temp, w	; seconda inversione di w_temp, risultato in W (W contiene il valore precedente all'interrupt)
		; fine interrupt
		retfie               
		
		end			; fine firmware


