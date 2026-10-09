import Foundation

/// Common given names (lower case, ~2082 entries across many languages).
/// A lower-case word after a greeting ("hi i'm priya" — typical speech-to-text
/// output) is accepted as a name ONLY when it is in this list, so "hi i'm stuck"
/// or "hi i'm grumpy" never become names. Capitalised names do not need it.
enum FirstNames {
    static let all: Set<String> = Set(raw.split(whereSeparator: \.isWhitespace).map(String.init))

    static func contains(_ word: String) -> Bool { all.contains(word.lowercased()) }

    private static let raw = """
    aanya aarav aaron abbey abbie abby abdul abdullah abel abena abhishek abigail abraham abram ada adam
    adan addison ade adela adelaide adele adeline aden adil adina aditi aditya adnan adolfo adria adrian
    adriana adrianna adrienne afia afua agatha agnes agnieszka agustin ahmad ahmed ahmet aida aidan
    aiden aiko ailsa aimee aine aisha aishwarya aiyana ajay akash akiko akira akosua aksel akshay akua
    alaina alan alana alanna alba albert alberta alberto albie alden aldo alec alecia alejandra
    alejandro aleksander aleksandra alena alessandra alessandro alessia alex alexa alexander alexandra
    alexandre alexandria alexei alexey alexia alexis alfie alfonso alfred alfredo ali alia alice alicia
    alina alisha alison alissa alistair alivia aliya aliyah alize allan allen allie allison ally allyson
    alma alonso alonzo alvaro alvin alya alyssa ama amado amal amanda amani amara amari amaya ambrose
    amelia amelie amina amir amira amit amitabh amos amy ana anabel anahi anais anand ananya anastasia
    anastasiya anaya anders anderson andi andre andrea andreas andreea andrei andres andrew andrzej andy
    aneesh angel angela angelica angelina angelo angie angus anika anil anirudh anisha anita anja anjali
    ankit ann anna annabel annabelle annalise anne anneliese annette annie annika anouk ansel anthony
    antoine antoinette anton antonia antonio anushka anya apollo april araceli arash archer archie ari
    aria ariadne ariana arianna ariel arielle arjun arlene arlo armand armando arnav arne arnold aron
    arthur arturo arun arya aryan asa asad asha ashby asher ashlee ashley ashlyn ashok ashton ashwin
    asif asma aspen astrid athena atticus aubree aubrey audra audrey august augusta augustine aurelia
    aurora austin autumn ava avery avi avraham axel aya ayaan ayanna ayesha ayla ayo ayse ayumi azadeh
    aziz azra bailey baraka barbara barnaby barney barry bart bartek bartholomew bartosz basil bastian
    bea beatrice beatriz beau becca beckett becky belinda bella ben benedict benjamin bennett benny
    benoit bernadette bernard bernardo bernice bernie bert bertha bethany betsy betty beverly bhavna
    bianca bilal bill billie billy bjorn blaine blair blake blanca blythe bo bobbi bobbie bobby bodhi
    bogdan bola bongani bonnie boris brad bradley brady braeden bram branden brandi brandon brandy
    branson braxton brayden brenda brendan brenna brennan brent brett brian briana brianna bridget
    brielle brigitte britney britt brittany brock brody bronwyn brooke brooklyn brooks bruce bruno bryan
    bryant bryce bryn bryony bryson burak byron caden caitlin caitlyn cal caleb callie callum calum
    calvin cameron camila camilla camille campbell candace candice cara carina carl carla carlo carlos
    carlton carly carmen carol carole carolina caroline carolyn carrie carson carter casey cassandra
    cassidy cassie catalina caterina catherine cathy cecil cecilia cedric celeste celia celine cesar
    chad chaim chandler chantal charity charlene charles charley charlie charlize charlotte chaya
    chelsea chen cheng cher cheryl chester chetan cheyenne chiara chidi chinedu chinwe chioma chip chloe
    chris chrissy christa christian christiane christina christine christoph christophe christopher
    christy chuck cian ciara ciaran cindy claire clara clare clarence clarissa clark claude claudia
    claudio clay clayton clement clementine cleo cliff clifford clint clinton clive cody colby cole
    coleen colette colin colleen collin colton conan conner connie connor conor conrad constance
    constantin cooper cora coral corbin cordelia corey corinne cormac cornelius cory courtney craig
    cristian cristina cristobal crystal cullen curtis cyril cyrus daan dafydd dagny dahlia daiki daisy
    dakota dale dalia dallas damian damien damon dan dana dane dani daniel daniela daniele daniella
    danielle danny dante daphne dara darcy daria darian dario darius darnell darrell darren darryl daryl
    dave david davina davis dawn dean deanna debbie debora deborah debra declan deepa deepak deepika
    deirdre delaney delia della delphine demetrius dena denis denise dennis denzel derek dermot desiree
    desmond destiny devika devin devon dexter dhruv diana diane dianne diego dieter dilan dillon dimitri
    dina dinah dinesh dino dion dionne dirk divya dmitri dmitry dolores dominic dominick dominik
    dominique don donald donna donovan dora doreen dorian doris dorothy doug douglas drake drew duane
    duncan dustin dwayne dwight dylan ean earl easton eddie eden edgar edie edith edmund edna eduardo
    edward edwin effie eileen ekaterina elaine elan eleanor eleanora elena eli elia elian eliana elias
    elif elijah elin elina elinor eliot elisa elisabeth elise eliza elizabeth ella elle ellen ellery
    ellie elliot elliott ellis elmer eloise elsa elsie elton elvis elyse emanuel emeka emerson emery emi
    emil emilia emiliano emilie emilio emily emir emma emmanuel emmett emmy emre ena enrique enzo eoin
    ephraim eric erica erik erika erin ernest ernesto errol esi esme esmeralda esperanza esteban estelle
    esther ethan etienne eugene eun eunice eva evan evangeline eve evelyn everett evie ewa ewan ezekiel
    ezra fabian fabio faisal faith fang farah farhan farid farrah fatima fatma fay faye federico felicia
    felicity felipe felix femke feng fergus fernanda fernando ffion filip finlay finley finn finnegan
    fiona fitz flavia fletcher flora florence florian floyd flynn forrest francesca francesco francine
    francis francisco franco francois frank frankie franklin franz fraser fred freddie freddy frederick
    freja freya frida fritz gabe gabriel gabriela gabriella gabrielle gael gage gail galen gareth
    garrett garry gary gaspard gaurav gavin geeta gemma gene genevieve geoff geoffrey george georgia
    georgina gerald geraldine gerard gerardo gerhard gia giada gianna gideon gil gilbert gilles gillian
    gina ginny gino giorgio giovanna giovanni gisele giselle giulia giulio giuseppe gladys glen glenda
    glenn gloria gordon grace gracie graham grant greg gregor gregory greta gretchen griffin guadalupe
    guillaume guillermo gunnar gus gustav gustavo guy gwen gwendolyn habib hadi hadley hailey hakan
    haley halle hamid hamish hamza hana hank hanna hannah hans hao harish harlan harley harold harper
    harriet harris harrison harry haruto harvey hasan hassan hayden hayley heath heather hector heidi
    helen helena helga hemant henri henrietta henrik henry herbert herman hilary hilda hillary hina hiro
    hiroko hiroshi hollie holly homer hong hope horace howard hoyt hudson hugh hugo hui humberto hunter
    hussein hyun iain ian ibrahim ida idris ifeoma ignacio igor ike ilana ilse ilya imani imogen imran
    ina inaya india indira indy ines inez inga ingrid iona ira irene irina iris irma isa isaac isabel
    isabela isabella isabelle isaiah isak isha ishaan ishita isla ismael ivan ivana ivy iyla jabari jace
    jack jackie jackson jaclyn jacob jacqueline jacques jada jade jaden jagger jaime jake jakob jakub
    jamal james jameson jamie jan jana jane janelle janet janice janine jared jarrett jasmine jason
    jasper jatin javier jay jaya jayden jayne jean jeanette jeanne jeff jefferson jeffrey jen jenna
    jennifer jenny jeremiah jeremy jerome jerry jesper jess jesse jessica jessie jesus jethro jian jie
    jill jillian jim jimena jimin jimmy jin jing jiwoo jo joan joanna joanne joao jocelyn jodi jodie
    jody joe joel joelle joey johan johann johanna john johnny jolene jon jonah jonas jonathan joon
    joost jordan jordi jordyn jorge jose josef joseph josephine josh joshua josiah josie joy joyce juan
    juana judah jude judith judy jules julia julian juliana julie julien juliet julieta julio julius jun
    june junior jurgen justin justine kabir kacper kade kai kaia kaitlyn kaiya kaja kale kamal kamala
    kamau kamila kara karan kareem karen kari karim karin karina karl karla karolina karthik kasey kasia
    katarzyna kate katelyn katerina katharine katherine kathleen kathryn kathy katie katrina kavya kay
    kaya kayla kaylee kazuki keanu keegan keiko keira keisha keith kellan kelly kelsey kelvin ken
    kendall kendra kenji kenneth kenny kent kenta kenya kenzie kerem keri kerry kevin khadija khalid
    khalil kian kiara kieran kim kimberly kimi kingsley kira kiran kirsten kit kobe koen kofi kojo kris
    krishna krista kristen kristian kristin kristina kristof krzysztof kumar kurt kwabena kwame kyle
    kylie kyra lacey lachlan laila lakshmi lalita lamar lana lance landon lara larissa larry lars laszlo
    latisha laura lauren laurence laurent laurie lawrence layla lea leah leandro lee leela lei leif
    leila leilani lena lennon lenny leo leon leona leonard leonardo leonie leopold lerato leroy lesley
    leslie lester levi lewis lexi li lia liam liana libby lila lilah lili lilian liliana lillian lilly
    lily lin lina lincoln linda lindsay lindsey ling linnea lionel lisa liv livia liz liza lizzie lloyd
    logan lois lola london lorena lorenzo loretta lori lorna lorraine lotte lottie lou louie louis
    louisa louise luana luca lucas lucia lucian luciana luciano lucie lucille lucy luis luisa lukas luke
    luna lydia lyla lyle lynn lynne maartje mabel macie maciej mackenzie madeleine madeline madelyn
    madhu madison mae maeve magda magdalena maggie magnus mahesh mahmoud mai maia maisie maite maja
    makayla malachi malcolm malgorzata malia malik malika mallory manish manoj manon manuel manuela mara
    marc marcel marcela marcella marcello marcia marco marcos marcus marek margaret margarita margaux
    margot maria mariah mariam marian mariana marianne mariano maribel marie mariela marilyn marina
    mario marion marisa marissa marius marjorie mark marko marla marlene marley marlon marta martha
    martin martina marty marvin mary maryam mason mateo mathias mathieu matilda matt matteo matthew
    matthias mattie maud maura maureen maurice mauricio max maxim maxime maximilian maxine maxwell maya
    mckenzie meena meera megan meghan mehmet mei melanie melinda melissa melody melvin mercedes meredith
    mia micah michael michaela michal michel michele michelle miguel mikaela mike mikhail mila milan
    milena miles miley millie milo mina mindy ming minh minjun mira miranda miriam misha mitchell
    mohamed mohammad mohammed mohan moira moises molly mona monica monika monique morgan moses muhammad
    murat muriel murray mustafa myles myra nadia nadine naledi nancy nandini naoko naomi naresh narges
    nash natalia natalie natalya natasha nate nathalie nathan nathaniel naveen navid neal neelam neha
    neil nell nellie nelson nestor ngozi niall nicholas nick nicky nico nicola nicolas nicole nigel
    nikhil niki nikita nikki nikola nikolai nikolay nils nina ning nisha nnamdi noah noel noelle noemi
    nomvula nora norah norma norman nour nova nuno obinna octavia odette odin oguz oksana olek olga oli
    oliver olivia ollie olumide oluwaseun omar omari oren orion orla orlando oscar osman otis otto owen
    ozan pablo padma paige pamela paola paolo paris parker pascal patricia patrick patsy patty paul
    paula pauline pavel pawel pearl pedro peggy penelope penny percy perry pete peter petra philip
    philippa phillip phoebe phoenix pierce pierre pieter pilar ping piotr piper pippa polly pooja
    pradeep prakash pranav preeti preston priscilla priya priyanka prudence qasim qiang queenie quentin
    quincy quinn rachael rachel rafael rafaela raheem rahul raina raj rajesh rajiv rakesh ralph ramesh
    ramin ramon ramona randall randy rani rania raphael raquel rashid raul raven ravi ray raymond reagan
    rebecca rebekah reed reese regan reggie regina reginald reid rekha remi remy rena renata rene renee
    reuben rex reza rhea rhiannon rhys ricardo richard rick ricky rihanna riko riley rita ritu river rob
    robbie robert roberta roberto robin rocco rocio rod roderick rodney rodrigo rohan rohit roisin
    roland rolf roman romeo ron ronald ronan ronnie rory rosa rosalie rosalind rosanna rose rosemary
    rosie ross rowan roxanne roy ruben ruby rudy rufus rupert russell ruth ryan ryder ryo saanvi sabine
    sabrina sachin sadie sahil saif sakura sally salma salvador sam samantha samara sameer sami samir
    samira sammy samson samuel sana sandeep sander sandra sandy sanjana sanjay sanna sanne santiago
    santino santosh sapna sara sarah sasha saskia saul savannah sawyer scarlett scott sean sebastian
    selena selin selina selma seojun seoyeon serena sergei sergey sergio seth seymour shalini shane
    shanice shankar shannon sharmila sharon shaun shauna shawn shawna sheila shelby shelley sherry
    shirley shiv shreya shruti shun shweta siddharth sidney siena sienna sigrid silas silvia simon
    simone siobhan sione sipho sky skye skyler smita sneha sofia sofie sonal sonia sonja soo sophia
    sophie sota spencer stacey stacy stan stanley stefan stefanie stella stephan stephanie stephen
    sterling steve steven stewart stuart sudha sue sumit sunil sunita suresh susan susanna susanne
    suzanne sven svetlana swati sydney sylvia sylvie tabitha takeshi talia tamara tami tamsin tania
    tanner tanvi tanya tao tara tariq tarun tasha tatiana tatyana taylor ted teddy teresa terrence terri
    terry tess tessa thabo thandiwe thea themba theo theodore theresa thiago thomas tia tiago tiana
    tiffany tim timothy tina tobias toby todd tom tomas tomasz tommy toni tony tori tracey tracy travis
    trent trevor trinity tristan troy trudy tucker tunde ty tyler tyrone uche uday ulrich uma una uriel
    ursula usha uzma valentina valentino valeria valerie vanessa varsha varun vasilis vaughn vera
    veronica vicente vicki victor victoria vihaan vijay vikas vikram vinay vince vincent vinod viola
    violet virginia vito vivek vivian viviane vladimir vladislav wade walker wallace walter wanda
    wanjiru warren wayne wei wendell wendy wesley weston whitney wilbur wilfred will willa willem
    william willie willow wilma wilson winifred winnie winston wojciech wyatt xander xavier xena xiao
    ximena xin yael yan yang yara yash yasmin yasmine yaw yesenia yi ying yoko yolanda yosef young
    yousef yu yui yuki yuliya yuri yusuf yuto yvette yvonne zac zach zachary zahra zain zainab zak
    zander zane zanele zara zayn zbigniew zeke zelda zeynep zhen zoe zoey zofia zora zosia zuri
    """
}
